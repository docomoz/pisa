import Foundation

enum MeetingSpeechText {
    // Match any letter outside the Latin and Cyrillic scripts.
    private static let foreignLetters = try! NSRegularExpression(pattern: #"[^\P{L}\p{Latin}\p{Cyrillic}]"#)

    static func accepts(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: CharacterSet.letters.contains)
            && !containsForeignLetters(text)
    }

    static func containsForeignLetters(_ text: String) -> Bool {
        foreignLetters.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    static let unidentifiedSpeaker = "Собеседники"

    public var id: UUID = UUID()
    public var start: Double
    public var end: Double
    public var speaker: String
    public var embedding: [Float]?
    public var audioFile: String?
    public var text: String
    public var displayText: String {
        guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
        return String(text[..<index]) + text[index].uppercased() + text[text.index(after: index)...]
    }
    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start; self.end = end; self.speaker = speaker; self.text = text
    }
}
public enum MeetingStatus: String, Codable, Sendable { case recorded, processing, ready, failed }
public enum MeetingTitleOrigin: String, Codable, Sendable { case generated, custom }
public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public enum InterruptedTranscriptionProgress: Equatable, Sendable {
        case savedAudio(Double)
        case batch(Double)
    }

    public var id: UUID = UUID()
    public var title: String
    public var date: Date = Date()
    public var source: String
    public var duration: Double = 0
    public var status: MeetingStatus = .recorded
    public var segments: [TranscriptSegment] = []
    /// End of the prefix whose live draft was saved atomically with segments.
    public var liveCommittedUntil: Double?
    /// Last reported pipeline progress for an interrupted batch attempt.
    public var interruptedBatchProgress: Double?
    public var interruptedTranscriptionProgress: InterruptedTranscriptionProgress? {
        guard status == .failed else { return nil }
        if let interruptedBatchProgress, (0...1).contains(interruptedBatchProgress) {
            // A batch still has to save the transcript after its pipeline reaches 100%.
            return .batch(min(interruptedBatchProgress, 0.99))
        }
        return LiveTranscriptionSchedule.audioProgress(committed: liveCommittedUntil, duration: duration)
            .map(InterruptedTranscriptionProgress.savedAudio)
    }
    public var audioFiles: [String] = []
    public var audioOffsets: [String: Double] = [:]
    public var error: String?
    public var notes: String = ""
    public var exportedAt: Date?
    public var folderID: UUID?
    public var deletedAt: Date?
    public var automaticTitle: String?
    public var titleOrigin: MeetingTitleOrigin?
    public var hasAutomaticTitle: Bool {
        guard titleOrigin == nil else { return false }
        if let automaticTitle { return title == automaticTitle }
        func normalized(_ text: String) -> String { text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        let stamps = [meetingDateLabel(date, showsRelativeDay: false), date.formatted(date: .abbreviated, time: .shortened), date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "ru_RU")))]
        return ["Встреча", "Созвон", "Запись"].contains { prefix in
            stamps.contains { normalized(prefix + " · " + $0) == normalized(title) }
        }
    }
    private var defaultTitlePrefix: String { source == "Аудиофайл" ? "Запись" : "Созвон" }
    public var defaultTitle: String { defaultTitlePrefix + " · " + meetingDateLabel(date, showsRelativeDay: false) }
    public var headingTitle: String { hasAutomaticTitle ? defaultTitlePrefix : title }
    @discardableResult public mutating func refreshAutomaticTitle() -> Bool {
        guard hasAutomaticTitle else { return false }
        let changed = title != defaultTitle || automaticTitle != defaultTitle
        title = defaultTitle; automaticTitle = title
        return changed
    }
    public var needsGeneratedTitle: Bool {
        status == .ready && liveCommittedUntil == nil &&
        (hasAutomaticTitle || titleOrigin == .generated) &&
        segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    @discardableResult public mutating func applyGeneratedTitle(_ value: String) -> Bool {
        guard needsGeneratedTitle, let clean = MeetingTitleComposer.cleanTitle(value) else { return false }
        title = clean; titleOrigin = .generated; automaticTitle = nil
        return true
    }
    @discardableResult public mutating func rename(to value: String, resetIfEmpty: Bool = false) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            guard resetIfEmpty, !hasAutomaticTitle else { return false }
            title = defaultTitle; titleOrigin = nil; automaticTitle = title
        } else {
            title = clean; titleOrigin = .custom; automaticTitle = nil
        }
        return true
    }
    public init(title: String, source: String) { self.title = title; self.source = source }
    public var speakers: [String] { Array(Set(segments.map(\.speaker))).sorted() }
    var participantNames: [String] { speakers.filter { $0 != TranscriptSegment.unidentifiedSpeaker } }
    public var searchableText: String { ([title, source, notes] + segments.map { "\($0.speaker) \($0.text)" }).joined(separator: " ") }
}
public struct Preferences: Codable, Sendable {
    public var automaticRecording = false
    public var mcpEnabled = true
    public var exportBookmark: Data?
    public var exportDisplayPath: String?
    public var modelBookmark: Data?
    public var modelDisplayPath: String?
    public var vocabulary = "2ГИС, Яндекс, YClients"
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
/// Use relative days for display and include the year from the first calendar anniversary.
public func meetingDateLabel(_ date: Date, now: Date = Date(), calendar: Calendar = .current, showsRelativeDay: Bool = true, compact: Bool = false) -> String {
    var timeStyle = Date.FormatStyle().hour().minute().locale(Locale(identifier: "ru_RU"))
    timeStyle.calendar = calendar
    timeStyle.timeZone = calendar.timeZone
    if showsRelativeDay {
        if calendar.isDate(date, inSameDayAs: now) {
            return typographicText("Сегодня в \(date.formatted(timeStyle))")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return typographicText("Вчера в \(date.formatted(timeStyle))")
        }
    }
    let anniversary = calendar.date(byAdding: .year, value: 1, to: date) ?? .distantFuture
    var style = compact ? timeStyle.day(.twoDigits).month(.twoDigits) : timeStyle.day().month(.wide)
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

/// Finished sidebar entries use whole minutes, rounded up; live timers remain exact.
public func sidebarDuration(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    guard seconds > 0 else { return "0\u{00A0}мин" }
    let rounded = max(1, ceil(seconds / 60))
    guard rounded < Double(Int.max) else { return "—" }
    let minutes = Int(rounded)
    let hours = minutes / 60, remainder = minutes % 60
    if hours == 0 { return "\(minutes)\u{00A0}мин" }
    if remainder == 0 { return "\(hours)\u{00A0}ч" }
    return "\(hours)\u{00A0}ч\u{00A0}\(remainder)\u{00A0}мин"
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

public struct VoiceProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var samples: [[Float]]
    public var model = "titanet-large-v1"
    public var examples: [VoiceExample]?
    public init(name: String, samples: [[Float]]) { self.name = name; self.samples = samples }

    /// The corrected name may resolve an identity conflict on the next audio assessment.
    mutating func requestIdentityRevalidation() {
        guard var examples else { return }
        for index in examples.indices where examples[index].exclusionReason == .identityConflict {
            examples[index].embeddingRevision = nil
        }
        self.examples = examples
    }

    /// Apply completed work to the current examples, which can change while the audio is read.
    mutating func refreshExampleEmbeddings(_ refreshed: [UUID: VoiceExample]) -> Bool {
        guard var examples, !refreshed.isEmpty else { return false }
        var sampleIndices: [[Float]: [Int]] = [:]
        for index in samples.indices.reversed() { sampleIndices[samples[index], default: []].append(index) }
        var changed = false
        for index in examples.indices {
            let current = examples[index]
            let sampleIndex = sampleIndices[current.embedding]?.popLast()
            guard current.needsEmbeddingRefresh, let replacement = refreshed[current.id],
                  replacement.file == current.file, replacement.meetingID == current.meetingID,
                  replacement.segmentID == current.segmentID,
                  replacement.embeddingRevision == VoiceExample.currentEmbeddingRevision,
                  VoiceMatcher.similarity(replacement.embedding, replacement.embedding) > 0 else { continue }
            examples[index] = replacement
            if let sampleIndex {
                samples[sampleIndex] = replacement.embedding
            } else {
                samples.append(replacement.embedding)
            }
            changed = true
        }
        if changed { self.examples = examples }
        return changed
    }
}
public struct VoiceMatcher {
    private struct Sample {
        var vector: [Float]
        var example: VoiceExample?
        var competitorSimilarity: Float = -1
    }
    private struct Candidate {
        let name: String
        var samples: [Sample]
        var corroborators: [[Int]]
    }
    private let candidates: [Candidate]

    public init(profiles: [VoiceProfile]) {
        self.init(profiles: profiles, legacyEvidenceForExclusion: false)
    }
    /// Legacy evidence may conservatively reject enrollment, but never lowers
    /// the confidence required to assign a name during recognition.
    static func enrollmentConflict(_ embedding: [Float], name: String, profiles: [VoiceProfile]) -> String? {
        VoiceMatcher(profiles: profiles.filter { $0.name != name }, legacyEvidenceForExclusion: true)
            .identify(embedding, requiringCorroboration: true)
    }
    private init(profiles: [VoiceProfile], legacyEvidenceForExclusion: Bool) {
        var candidates: [Candidate] = []
        for (name, voices) in Dictionary(grouping: profiles, by: \.name) {
            var samples: [Sample] = []
            for voice in voices {
                var examplesByEmbedding: [[Float]: [VoiceExample]] = [:]
                for example in (voice.examples ?? []).reversed() {
                    examplesByEmbedding[example.embedding, default: []].append(example)
                }
                for vector in voice.samples where Self.similarity(vector, vector) > 0 {
                    let example = examplesByEmbedding[vector]?.popLast()
                    // Consume excluded examples too, so their paired vectors
                    // cannot reenter matching as unpaired legacy training.
                    guard example?.excludedFromRecognition != true else { continue }
                    let verified = legacyEvidenceForExclusion || example?.embeddingRevision == VoiceExample.currentEmbeddingRevision ? example : nil
                    samples.append(Sample(vector: vector, example: verified))
                }
            }
            guard !samples.isEmpty else { continue }
            let verified = samples.indices.filter { samples[$0].example != nil }
            let corroborated = verified.contains { index in
                verified.contains { Self.independent(samples[index], samples[$0]) &&
                    Self.similarity(samples[index].vector, samples[$0].vector) >= 0.55 }
            }
            if corroborated {
                // A coherent pair can protect its profile from a disconnected clip.
                // Preserve all clips in storage and keep legacy vectors eligible.
                samples = samples.indices.filter { index in
                    samples[index].example == nil || verified.contains { peer in
                        index != peer && Self.similarity(samples[index].vector, samples[peer].vector) >= 0.45
                    }
                }.map { samples[$0] }
            }
            let corroborators = samples.indices.map { index in
                samples.indices.filter { other in
                    Self.independent(samples[index], samples[other]) &&
                        Self.similarity(samples[index].vector, samples[other].vector) >= 0.55
                }
            }
            candidates.append(Candidate(name: name, samples: samples, corroborators: corroborators))
        }
        for candidate in candidates.indices {
            let competitors = candidates.indices.filter { $0 != candidate }.flatMap { candidates[$0].samples }
            for index in candidates[candidate].samples.indices where candidates[candidate].samples[index].example != nil {
                let vector = candidates[candidate].samples[index].vector
                candidates[candidate].samples[index].competitorSimilarity = competitors.map { Self.similarity(vector, $0.vector) }.max() ?? -1
            }
        }
        self.candidates = candidates
    }

    private static func independent(_ first: Sample, _ second: Sample) -> Bool {
        guard let first = first.example, let second = second.example else { return false }
        return first.meetingID != second.meetingID && first.file != second.file && first.embedding != second.embedding
    }

    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, aa: Float = 0, bb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; aa += a[i] * a[i]; bb += b[i] * b[i] }
        let product = aa * bb
        guard dot.isFinite, product.isFinite, product > 0 else { return -1 }
        return dot / product.squareRoot()
    }
    public static func identify(_ embedding: [Float], profiles: [VoiceProfile]) -> String? {
        VoiceMatcher(profiles: profiles).identify(embedding)
    }
    public func identify(_ embedding: [Float]) -> String? {
        identify(embedding, requiringCorroboration: false)
    }
    func identify(_ embedding: [Float], requiringCorroboration: Bool) -> String? {
        let scores = candidates.map { $0.samples.map { Self.similarity(embedding, $0.vector) } }
        let bestByCandidate = scores.map { $0.max() ?? -1 }
        guard let winner = candidates.indices.max(by: { bestByCandidate[$0] < bestByCandidate[$1] }) else { return nil }
        let best = bestByCandidate[winner]
        let competing = candidates.indices.filter { $0 != winner }.map { bestByCandidate[$0] }.max() ?? -1
        guard best >= 0.60, best - competing >= 0.06 else { return nil }

        let candidate = candidates[winner]
        for index in candidate.samples.indices where scores[winner][index] == best {
            let sample = candidate.samples[index]
            // A close match to an enrollment shared acoustically with another
            // identity still needs a distinctive second sample.
            if !requiringCorroboration && best >= 0.78 && sample.competitorSimilarity < 0.70 { return candidate.name }
            guard best - competing >= 0.10, best - sample.competitorSimilarity >= 0.03 else { continue }
            if candidate.corroborators[index].contains(where: { other in
                let support = scores[winner][other]
                return support >= 0.50 && support - competing >= 0.04 &&
                    support - candidate.samples[other].competitorSimilarity >= 0.01
            }) {
                return candidate.name
            }
        }
        return nil
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
private let typographyPercentRegex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}/=])([0-9]+(?:[.,][0-9]+)?)[ \t\u00a0\u202f]+%(?![0-9A-Fa-f]{2})"#)
private let typographyCurrencyRegex = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}/=])([0-9]+(?:[.,][0-9]+)?)[ \t\u00a0]*₽(?![0-9A-Fa-f]{2})"#)
private let typographyDollarRegex = try? NSRegularExpression(pattern: #"(?i)(`+)[\s\S]*?\1|(?<![^\s«(])(?:за|от|до|по)(?=\$[0-9]+(?:[.,][0-9]+)?[.,!?;:»)]*(?!\S))"#)
public func typographicText(_ value: String) -> String {
    var text = value
    for (regex, template) in [(typographyRegex, "$1\u{00a0}"), (typographyNumberRegex, "$1\u{00a0}$2"),
                              (typographyPercentRegex, "$1%"), (typographyCurrencyRegex, "$1\u{00a0}₽")] {
        if let regex { text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template) }
    }
    if text.contains("$"), let typographyDollarRegex {
        // The first alternative consumes backtick-quoted code without editing it.
        let revised = NSMutableString(string: text)
        let matches = typographyDollarRegex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() where match.range(at: 1).location == NSNotFound {
            revised.insert("\u{00a0}", at: NSMaxRange(match.range))
        }
        text = revised as String
    }
    return text
}

/// UTF-16 ranges can be applied to both plain and typographically spaced text.
public func transcriptSearchRanges(in text: String, query: String) -> [NSRange] {
    guard !query.isEmpty else { return [] }
    let searchable = text.replacingOccurrences(of: "\u{00a0}", with: " ") as NSString
    let needle = query.replacingOccurrences(of: "\u{00a0}", with: " ")
    var remaining = NSRange(location: 0, length: searchable.length)
    var matches: [NSRange] = []
    while remaining.length > 0 {
        let match = searchable.range(of: needle, options: .caseInsensitive, range: remaining, locale: .current)
        guard match.location != NSNotFound, match.length > 0 else { break }
        matches.append(match)
        let next = NSMaxRange(match)
        remaining = NSRange(location: next, length: searchable.length - next)
    }
    return matches
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
public struct VoiceExample: Codable, Identifiable, Equatable, Sendable {
    enum ExclusionReason: String, Codable, Sendable {
        case overlappingSpeech, identityConflict
    }

    static let currentEmbeddingRevision = 2
    public var id = UUID()
    public var file: String
    public var meetingID: UUID
    public var segmentID: UUID
    public var embedding: [Float]
    var embeddingRevision: Int?
    var excludedFromRecognition: Bool?
    var exclusionReason: ExclusionReason?
    var needsEmbeddingRefresh: Bool { (embeddingRevision ?? 0) < Self.currentEmbeddingRevision }

    public init(file: String, meetingID: UUID, segmentID: UUID, embedding: [Float]) {
        self.file = file; self.meetingID = meetingID; self.segmentID = segmentID; self.embedding = embedding
    }
    func withCurrentEmbedding(_ embedding: [Float]) -> Self {
        var updated = self
        updated.embedding = embedding
        updated.embeddingRevision = Self.currentEmbeddingRevision
        return updated
    }
}

/// MeetingView's visibility decisions, independent of SwiftUI and audio I/O.
/// Keep saved audio reachable after interruption and transcript tools hidden until ready.
/// Regression history: e891567, 6f77960 and 1b6b5fb.
struct MeetingPresentation: Equatable, Sendable {
    let isRecording: Bool
    let isSaving: Bool
    let isQueued: Bool
    let isTranscribing: Bool
    let showsTranscriptTools: Bool
    let showsAutomaticPlayer: Bool
    let showsTranscriptStatus: Bool
    /// Permission to inspect saved tracks; the view still checks their actual availability.
    let allowsSavedAudio: Bool

    init(meeting: Meeting, recordingID: UUID?, savingID: UUID?, processingID: UUID?, isQueued: Bool) {
        isRecording = recordingID == meeting.id
        isSaving = savingID == meeting.id
        self.isQueued = isQueued
        isTranscribing = meeting.status == .processing && processingID == meeting.id
        showsTranscriptTools = meeting.status == .ready && !isRecording && !isSaving && !isQueued
        showsAutomaticPlayer = !showsTranscriptTools && meeting.segments.isEmpty
        showsTranscriptStatus = isSaving || isTranscribing || isQueued || (meeting.status == .failed && !meeting.segments.isEmpty)
        allowsSavedAudio = !isRecording && !isSaving
    }
}
