import Foundation

struct UsageEvent: Codable, Equatable {
    let type: String
    let parameters: [String: String]
    let minutes: Double?

    private static func duration(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return (min(seconds, 86_400) / 6).rounded() / 10
    }
    private static func mode(_ value: String) -> String {
        ["live", "resume", "batch"].contains(value) ? value : "other"
    }
    private static func flag(_ value: Bool) -> String { value ? "yes" : "no" }
    static let appLaunched = UsageEvent(type: "App.launched", parameters: [:], minutes: nil)
    static let appActivated = UsageEvent(type: "App.activated", parameters: [:], minutes: nil)
    static func recordingStarted(automatic: Bool) -> Self {
        .init(type: "Recording.started", parameters: ["start": automatic ? "automatic" : "manual"], minutes: nil)
    }
    static func recordingSaved(duration: Double, automatic: Bool) -> Self {
        .init(type: "Recording.saved", parameters: ["start": automatic ? "automatic" : "manual"], minutes: self.duration(duration))
    }
    static func audioImported(duration: Double) -> Self {
        .init(type: "Audio.imported", parameters: [:], minutes: self.duration(duration))
    }
    static func transcriptionStarted(mode: String, reprocess: Bool) -> Self {
        .init(type: "Transcription.started", parameters: ["mode": self.mode(mode), "reprocess": flag(reprocess)], minutes: nil)
    }
    static func transcriptionCompleted(mode: String, reprocess: Bool, duration: Double) -> Self {
        .init(type: "Transcription.completed", parameters: ["mode": self.mode(mode), "reprocess": flag(reprocess)], minutes: self.duration(duration))
    }
    static func transcriptionFailed(mode: String, cancelled: Bool, reprocess: Bool) -> Self {
        .init(type: cancelled ? "Transcription.cancelled" : "Transcription.failed", parameters: ["mode": self.mode(mode), "reprocess": flag(reprocess)], minutes: nil)
    }
}

struct UsageEventQueue: Codable {
    struct Item: Codable, Equatable {
        let id: UUID
        let date: Date
        let event: UsageEvent
    }
    private(set) var pending: [Item] = []
    private let limit: Int
    init(limit: Int = 200) { self.limit = max(1, limit) }
    mutating func append(_ event: UsageEvent) {
        pending.append(Item(id: UUID(), date: Date(), event: event))
        if pending.count > limit { pending.removeFirst(pending.count - limit) }
    }
    mutating func acknowledge(_ sent: [Item]) {
        let ids = Set(sent.map(\.id))
        pending.removeAll { ids.contains($0.id) }
    }
    mutating func discardOlder(than cutoff: Date) { pending.removeAll { $0.date < cutoff } }
}
