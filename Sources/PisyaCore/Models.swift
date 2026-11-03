import Foundation

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var start: Double
    public var end: Double
    public var speaker: String
    public var embedding: [Float]?
    public var audioFile: String?
    public var text: String
    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}
public enum MeetingStatus: String, Codable, Sendable { case recorded, processing, ready, failed }
public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var title: String
    public var date: Date = Date()
    public var source: String
    public var duration: Double = 0
    public var status: MeetingStatus = .recorded
    public var segments: [TranscriptSegment] = []
    /// End of the prefix whose live draft was saved atomically with segments.
    public var liveCommittedUntil: Double?
    public var audioFiles: [String] = []
    public var audioOffsets: [String: Double] = [:]
    public var error: String?
    public var notes: String = ""
    public var exportedAt: Date?
    public var folderID: UUID?
    public var deletedAt: Date?
    public var automaticTitle: String?
    public var hasAutomaticTitle: Bool {
        if let automaticTitle { return title == automaticTitle }
        func normalized(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        let stamps = [meetingDateLabel(date), date.formatted(date: .abbreviated, time: .shortened), date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))]
        return ["Встреча", "Созвон", "Запись"].contains { prefix in
            stamps.contains { normalized(prefix + " · " + $0) == normalized(title) }
        }
    }
    public var defaultTitle: String {
        let prefix = source == "Аудиофайл" ? "Запись" : "Созвон"
        return prefix + " · " + meetingDateLabel(date)
    }
    @discardableResult public mutating func refreshAutomaticTitle() -> Bool {
        guard hasAutomaticTitle else { return false }
        let changed = title != defaultTitle || automaticTitle != defaultTitle
        title = defaultTitle; automaticTitle = title
        return changed
    }
    public init(title: String, source: String) { self.title = title; self.source = source }
    public var speakers: [String] { Array(Set(segments.map(\.speaker))).sorted() }
    public var searchableText: String { ([title, source, notes] + segments.map { "\($0.speaker) \($0.text)" }).joined(separator: " ") }
}
public struct Preferences: Codable, Sendable {
    public var automaticRecording = false
    public var mcpEnabled = false
    public var exportBookmark: Data?
    public var exportDisplayPath: String?
    public var modelBookmark: Data?
    public var modelDisplayPath: String?
    public var vocabulary = "2ГИС, Контур Толк"
    public var keepAudio = true
    public var quietProcessing: Bool?
    public var usesQuietProcessing: Bool { quietProcessing ?? true }
    public var backgroundTranscription: Bool?
    public var usesBackgroundTranscription: Bool { backgroundTranscription ?? true }
    public init() {}
}
public enum PisyaError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
/// Include the year only once the recording reaches its first calendar anniversary.
public func meetingDateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let anniversary = calendar.date(byAdding: .year, value: 1, to: date) ?? .distantFuture
    var style = Date.FormatStyle().day().month(.wide).hour().minute().locale(Locale(identifier: "ru_RU"))
    style.calendar = calendar; style.timeZone = calendar.timeZone
    if anniversary <= now { style = style.year() }
    return typographicText(date.formatted(style))
}
/// Elapsed clock: MM:SS before an hour, then HH:MM:SS.
public func recordingTimecode(_ seconds: Double) -> String {
    let t = seconds.isFinite ? Int(min(max(0, seconds), Double(Int.max / 2))) : 0
    return t >= 3600 ? String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
}
public func timecode(_ seconds: Double) -> String {
    let t = max(0, Int(seconds))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
}

/// Signal debouncing is independent of the UI, so muted/reconnect cases can be tested.
public struct CallDetector: Sendable {
    public enum Action: Equatable, Sendable { case start, stop, none }
    public var startDelay: TimeInterval = 3
    public var stopDelay: TimeInterval = 45
    private var activeSince: Date?
    private var inactiveSince: Date?
    private var recording = false
    private var suppressed = false
    public init() {}
    public mutating func manuallyStopped() { recording = false; suppressed = true; activeSince = nil }
    public mutating func reset() { activeSince = nil; inactiveSince = nil; recording = false; suppressed = false }
    public mutating func update(active: Bool, now: Date) -> Action {
        if active {
            inactiveSince = nil
            guard !suppressed else { return .none }
            if activeSince == nil { activeSince = now }
            if !recording, now.timeIntervalSince(activeSince!) >= startDelay { recording = true; return .start }
        } else {
            activeSince = nil
            if inactiveSince == nil { inactiveSince = now }
            if now.timeIntervalSince(inactiveSince!) >= stopDelay {
                suppressed = false
                if recording { recording = false; return .stop }
            }
        }
        return .none
    }
}

public struct VoiceProfile: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var samples: [[Float]]
    public var model = "titanet-large-v1"
    public var examples: [VoiceExample]?
    public init(name: String, samples: [[Float]]) { self.name = name; self.samples = samples }
}
public enum VoiceMatcher {
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        guard aa > 0, bb > 0 else { return -1 }
        return dot / (aa * bb).squareRoot()
    }
    public static func identify(_ embedding: [Float], profiles: [VoiceProfile]) -> String? {
        let ranked = profiles.map { p in (p.name, p.samples.map { similarity(embedding, $0) }.max() ?? -1) }.sorted { $0.1 > $1.1 }
        guard let first = ranked.first, first.1 >= 0.78, ranked.count == 1 || first.1 - ranked[1].1 >= 0.06 else { return nil }
        return first.0
    }
}

public func fragmentCount(_ n: Int) -> String {
    let tens = n % 100, ones = n % 10
    let ending = (11...14).contains(tens) ? "фрагментов" : ones == 1 ? "фрагмент" : (2...4).contains(ones) ? "фрагмента" : "фрагментов"
    return "\(n) \(ending)"
}

/// Presentation-only spacing; original transcript remains editable without substitutions.
private let typographyRegex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])([а-яё]{1,2}|без|для|при|под|над|или|что|как|чем|про|из-за|из-под)[ \\t]+")
private let typographyNumberRegex = try? NSRegularExpression(pattern: "(?i)(?<![\\p{L}\\p{N}])([0-9]+(?:[.,][0-9]+)?)[ \\t\\u00a0]+(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря|секунд[а-яё]*|минут[а-яё]*|час[а-яё]*|дн[а-яё]*|дней|месяц[а-яё]*|год[а-яё]*|года|лет|мс|КБ|МБ|ГБ|кГц|Гц|г\\.)(?![\\p{L}\\p{N}])")
private let typographyPercentRegex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}/=])([0-9]+(?:[.,][0-9]+)?)[ \\t\\u00a0]*([%₽])(?![0-9A-Fa-f]{2})")
public func typographicText(_ value: String) -> String {
    var text = value
    for (regex, template) in [(typographyRegex, "$1\u{00a0}"), (typographyNumberRegex, "$1\u{00a0}$2"), (typographyPercentRegex, "$1\u{00a0}$2")] {
        if let regex { text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template) }
    }
    return text
}

/// UI meters advance only from successfully written audio buffers, never synthetic activity.
public struct AudioMeterTrack: Sendable {
    public var history = [Float](repeating: 0, count: 512)
    public var historyTimes = [Double](repeating: 0, count: 512)
    public var seconds: Double = 0
    public var lastWrite: Double?
    public var level: Float = 0
    public init() {}
    public mutating func update(peak: Float, seconds: Double, lastWrite: Double?, now: Double) {
        self.seconds = seconds; self.lastWrite = lastWrite
        level = Self.displayLevel(peak)
        if !isFresh(now: now) { level = 0 }
        history.removeFirst(); history.append(level)
        historyTimes.removeFirst(); historyTimes.append(now)
    }
    public func isFresh(now: Double) -> Bool { lastWrite.map { now - $0 < 3 } ?? false }
    public static func displayLevel(_ amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        return min(1, max(0, (20 * log10(amplitude) + 60) / 60))
    }
}


public struct MeetingFolder: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var name: String
    public var symbol: String?
    public var iconName: String { symbol ?? "folder" }
    public init(name: String, symbol: String? = nil) { self.name = name; self.symbol = symbol }
}
public struct VoiceExample: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var file: String
    public var meetingID: UUID
    public var segmentID: UUID
    public var embedding: [Float]
    public init(file: String, meetingID: UUID, segmentID: UUID, embedding: [Float]) {
        self.file = file; self.meetingID = meetingID; self.segmentID = segmentID; self.embedding = embedding
    }
}
