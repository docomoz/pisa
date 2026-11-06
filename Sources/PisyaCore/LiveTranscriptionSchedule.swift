import Foundation

/// A single in-flight range. The cursor moves only after its result is durable.
public struct LiveTranscriptionSchedule: Sendable {
    public enum ProcessingMode: Equatable, Sendable { case fromStart, resume(Double) }
    public static func processingMode(committed: Double?, reprocess: Bool) -> ProcessingMode {
        if !reprocess, let committed { return .resume(committed) }
        return .fromStart
    }
    public static func audioProgress(committed: Double?, duration: Double?) -> Double? {
        guard let committed, let duration, duration.isFinite, duration > 0,
              committed >= 0, committed <= duration else { return nil }
        return committed / duration
    }
    public struct Window: Equatable, Sendable {
        public let start: Double
        public let end: Double
        fileprivate let attempt: UUID
    }
    public private(set) var committed: Double
    private let batchDuration: Double
    private var targetDuration: Double
    private var inFlight: Window?

    public init(batchDuration: Double = 15, committed: Double = 0) {
        precondition(batchDuration.isFinite && batchDuration > 0 && committed.isFinite && committed >= 0)
        self.batchDuration = batchDuration
        self.targetDuration = batchDuration
        self.committed = committed
    }
    public mutating func next(available: Double, stopped: Bool, paused: Bool = false) -> Window? {
        guard inFlight == nil, available.isFinite, available > committed, stopped || !paused else { return nil }
        guard stopped || available - committed >= targetDuration else { return nil }
        let window = Window(start: committed, end: min(available, committed + targetDuration), attempt: UUID())
        inFlight = window
        return window
    }
    public mutating func commit(_ window: Window, through end: Double? = nil) {
        guard inFlight == window else { return }
        let end = end ?? window.end
        guard end.isFinite, end > window.start, end <= window.end else { return }
        committed = end
        targetDuration = batchDuration
        inFlight = nil
    }
    public mutating func fail(_ window: Window) {
        if inFlight == window { inFlight = nil }
    }
    /// Retry an entirely uncommitted long turn only after another full batch
    /// of audio arrives. The maximum inference window remains bounded.
    @discardableResult public mutating func deferBoundary(_ window: Window) -> Bool {
        guard inFlight == window else { return false }
        inFlight = nil
        guard targetDuration < 60 else { return false }
        targetDuration = min(60, targetDuration + batchDuration)
        return true
    }

    /// Lookahead may contain utterances that straddle the planned boundary.
    /// Keep each whole crossing utterance in the uncommitted tail, including
    /// overlapping turns from the other track.
    public static func safeBoundary(start: Double, proposed: Double, segments: [TranscriptSegment]) -> Double {
        var boundary = proposed
        while let earlier = segments.filter({ $0.start < boundary && $0.end > boundary }).map(\.start).min(), earlier < boundary {
            let next = max(start, earlier)
            guard next < boundary else { break }
            boundary = next
        }
        return boundary
    }
}
