import Foundation

public final class MeetingLibrary: @unchecked Sendable {
    public let root: URL
    public var audioDirectory: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    public var meetingsDirectory: URL { root.appendingPathComponent("Meetings", isDirectory: true) }
    public init(root: URL) throws {
        self.root = root
        for dir in [root, audioDirectory, meetingsDirectory] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
    public func all(includeDeleted: Bool = false) throws -> [Meeting] {
        try FileManager.default.contentsOfDirectory(at: meetingsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: $0)) }
            .filter { includeDeleted || $0.deletedAt == nil }
            .sorted { $0.date > $1.date }
    }
    public func read(_ id: UUID) throws -> Meeting {
        try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: meetingsDirectory.appendingPathComponent(id.uuidString + ".json")))
    }
    public func save(_ meeting: Meeting) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: meetingsDirectory.appendingPathComponent(meeting.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    /// Remove only a failed startup journal; never discard existing audio or a transcript.
    public func discardEmptyDraft(_ meeting: Meeting) throws {
        guard meeting.segments.isEmpty else { return }
        for name in meeting.audioFiles {
            if FileManager.default.fileExists(atPath: try audioURL(name).path) { return }
        }
        let path = meetingsDirectory.appendingPathComponent(meeting.id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
    /// Only trashed meetings may be purged; shared audio remains available to other meetings.
    public func purgeTrashed(_ id: UUID) throws {
        let meeting = try read(id)
        guard meeting.deletedAt != nil else { throw PisyaError.message("Запись не находится в корзине") }
        let shared = Set(try all(includeDeleted: true).filter { $0.id != id }.flatMap(\.audioFiles))
        for name in meeting.audioFiles where !shared.contains(name) {
            let url = try audioURL(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        try FileManager.default.removeItem(at: meetingsDirectory.appendingPathComponent(id.uuidString + ".json"))
    }
    public func folders() throws -> [MeetingFolder] {
        let url = root.appendingPathComponent("folders.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([MeetingFolder].self, from: Data(contentsOf: url))
    }
    public func saveFolders(_ folders: [MeetingFolder]) throws {
        try JSONEncoder().encode(folders).write(to: root.appendingPathComponent("folders.json"), options: .atomic)
    }
    public func preferences() throws -> Preferences {
        let path = root.appendingPathComponent("preferences.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: path))
    }
    public func savePreferences(_ preferences: Preferences) throws {
        try JSONEncoder().encode(preferences).write(to: root.appendingPathComponent("preferences.json"), options: .atomic)
    }
    public func voices() throws -> [VoiceProfile] {
        let url = root.appendingPathComponent("voices.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VoiceProfile].self, from: Data(contentsOf: url))
    }
    public func saveVoices(_ voices: [VoiceProfile]) throws {
        try JSONEncoder().encode(voices).write(to: root.appendingPathComponent("voices.json"), options: .atomic)
    }
    public func audioURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name == URL(fileURLWithPath: name).lastPathComponent, !name.contains("..") else { throw PisyaError.message("Некорректное имя аудиофайла") }
        return audioDirectory.appendingPathComponent(name)
    }
}
public enum MarkdownExporter {
    private static let exportLock = NSLock()

    public static func render(_ meeting: Meeting) -> String {
        let formatter = ISO8601DateFormatter()
        let title = singleLine(meeting.title)
        var text = """
        ---
        id: \(meeting.id.uuidString)
        date: \(formatter.string(from: meeting.date))
        title: \(yamlString(title))
        source: \(yamlString(meeting.source))
        duration_seconds: \(meeting.duration)

        """
        let speakers = meeting.speakers
        if speakers.isEmpty {
            text += "speakers: []\n"
        } else {
            text += "speakers:\n"
            for speaker in speakers { text += "  - \(yamlString(speaker))\n" }
        }
        text += "---\n\n# \(title)\n\n"
        text += "Источник: \(meeting.source) · Длительность: \(timecode(meeting.duration))\n\n"
        if !meeting.notes.isEmpty { text += "## Заметки\n\n\(meeting.notes)\n\n" }
        text += "## Расшифровка\n\n"
        for s in meeting.segments { text += "**\(timecode(s.start)) · \(s.speaker)**\n\n\(typographicText(s.text))\n\n" }
        return text
    }
    /// Refresh the existing note by meeting ID so renaming a meeting preserves its links.
    public static func export(_ meeting: Meeting, to folder: URL, timeZone: TimeZone = .current) throws -> URL {
        exportLock.lock()
        defer { exportLock.unlock() }

        let markdown = render(meeting)
        if let existing = try changeExistingExport(for: meeting, in: folder, options: .forReplacing, change: {
            try markdown.write(to: $0, atomically: true, encoding: .utf8)
        }) {
            return existing
        }

        let files = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let stamp = formatter.string(from: meeting.date)
        let directory = monthDirectory(for: stamp, in: folder)

        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "\(stamp) — \(fileTitle(meeting.title))"
        var suffix = 1
        var url = directory.appendingPathComponent("\(stem).md")
        while files.fileExists(atPath: url.path) {
            suffix += 1
            url = directory.appendingPathComponent("\(stem) (\(suffix)).md")
        }
        // Publish a complete file without replacing a note created after the collision check.
        let staged = directory.appendingPathComponent(".pisya-\(UUID().uuidString).tmp")
        defer { try? files.removeItem(at: staged) }
        try markdown.write(to: staged, atomically: true, encoding: .utf8)
        try files.moveItem(at: staged, to: url)
        return url
    }

    /// Move the same note an automatic export would update, preserving any edits in the Trash.
    public static func trashExport(for meeting: Meeting, in folder: URL) throws -> URL? {
        exportLock.lock()
        defer { exportLock.unlock() }

        let files = FileManager.default
        guard files.isReadableFile(atPath: folder.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSURLErrorKey: folder])
        }
        var trashedURL: NSURL?
        _ = try changeExistingExport(for: meeting, in: folder, options: .forDeleting) {
            try files.trashItem(at: $0, resultingItemURL: &trashedURL)
        }
        return trashedURL as URL?
    }

    private static func changeExistingExport(
        for meeting: Meeting, in folder: URL, options: NSFileCoordinator.WritingOptions, change: (URL) throws -> Void
    ) throws -> URL? {
        let files = FileManager.default
        let legacy = folder.appendingPathComponent("pisya-\(meeting.id.uuidString.lowercased()).md")
        if files.fileExists(atPath: legacy.path), try changeOwnedExport(legacy, id: meeting.id, options: options, change: change) {
            return legacy
        }

        // Every possible local date falls within a day of the UTC date.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .gmt
        formatter.dateFormat = "yyyy-MM-dd"
        let dayLength: TimeInterval = 24 * 60 * 60
        let days = [0, -1, 1].map {
            String(formatter.string(from: meeting.date.addingTimeInterval(Double($0) * dayLength)).prefix(10))
        }
        let daysByDirectory = Dictionary(grouping: days) { monthDirectory(for: $0, in: folder) }
        for (month, possibleDays) in daysByDirectory {
            var isDirectory: ObjCBool = false
            guard files.fileExists(atPath: month.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if options.contains(.forDeleting) {
                let expected = monthDirectory(for: possibleDays[0], in: folder.resolvingSymlinksInPath())
                guard month.resolvingSymlinksInPath().path == expected.path else { continue }
            }
            let candidates = try files.contentsOfDirectory(at: month, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
            for candidate in candidates where candidate.pathExtension == "md" {
                let name = candidate.lastPathComponent
                let day = String(name.prefix(10))
                let automaticName = name.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}-[0-9]{2} — .+\.md$"#, options: .regularExpression) != nil
                if possibleDays.contains(day), automaticName,
                   try changeOwnedExport(candidate, id: meeting.id, options: options, change: change) {
                    return month.appendingPathComponent(candidate.lastPathComponent)
                }
            }
        }

        return nil
    }

    private static func monthDirectory(for stamp: String, in folder: URL) -> URL {
        folder.appendingPathComponent(String(stamp.prefix(4)), isDirectory: true)
            .appendingPathComponent(String(stamp.dropFirst(5).prefix(2)), isDirectory: true)
    }

    private static func belongsToMeeting(_ url: URL, id: UUID) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = 32 * 1024
        let data = try file.read(upToCount: limit) ?? Data()
        let prefix = String(decoding: data, as: UTF8.self)
        let lines = prefix.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.first == "---" else { return false }
        let end = lines.dropFirst().firstIndex(of: "---")
        guard let line = lines[1..<(end ?? lines.endIndex)].first(where: { $0.hasPrefix("id:") }) else { return false }
        let value = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        guard UUID(uuidString: value) == id else { return false }
        if end != nil { return true }
        // Large properties can put the closing delimiter beyond the normal read window.
        guard data.count == limit else { return false }
        let fullText = try String(contentsOf: url, encoding: .utf8)
        return fullText.split(whereSeparator: \.isNewline).dropFirst().contains("---")
    }

    private static func changeOwnedExport(
        _ url: URL, id: UUID, options: NSFileCoordinator.WritingOptions, change: (URL) throws -> Void
    ) throws -> Bool {
        guard try belongsToMeeting(url, id: id) else { return false }
        var coordinationError: NSError?
        var result: Result<Bool, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { coordinated in
            result = Result {
                guard try belongsToMeeting(coordinated, id: id) else { return false }
                try change(coordinated)
                return true
            }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? false
    }

    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: CharacterSet.newlines.union(.controlCharacters)).joined(separator: " ")
    }

    private static func yamlString(_ value: String) -> String {
        "'" + singleLine(value).replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static func fileTitle(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|[]#^")
        let clean = singleLine(title).components(separatedBy: forbidden).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-"))
        var result = ""
        for character in clean.trimmingCharacters(in: trim) {
            guard result.utf8.count + String(character).utf8.count <= 160 else { break }
            result.append(character)
        }
        result = result.trimmingCharacters(in: trim)
        return result.isEmpty ? "Встреча" : result
    }
}
