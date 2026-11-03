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
    public static func render(_ meeting: Meeting) -> String {
        let formatter = ISO8601DateFormatter()
        let title = meeting.title.replacingOccurrences(of: "\n", with: " ")
        var text = "---\nid: \(meeting.id.uuidString)\ndate: \(formatter.string(from: meeting.date))\n---\n\n# \(title)\n\n"
        text += "Источник: \(meeting.source) · Длительность: \(timecode(meeting.duration))\n\n"
        if !meeting.notes.isEmpty { text += "## Заметки\n\n\(meeting.notes)\n\n" }
        text += "## Расшифровка\n\n"
        for s in meeting.segments { text += "**\(timecode(s.start)) · \(s.speaker)**\n\n\(typographicText(s.text))\n\n" }
        return text
    }
    /// Stable ID prevents renamed titles creating orphaned copies; unrelated files are never overwritten.
    public static func export(_ meeting: Meeting, to folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("pisya-\(meeting.id.uuidString.lowercased()).md")
        try render(meeting).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
