import Foundation

struct SegmentAudioRange {
    let start: TimeInterval
    let end: TimeInterval
    var duration: TimeInterval { end - start }

    init?(start: TimeInterval, end: TimeInterval, offset: TimeInterval, duration: TimeInterval) {
        guard start.isFinite, end.isFinite, offset.isFinite, duration.isFinite,
              duration > 0, end > start else { return nil }
        let lower = max(0, start - offset)
        let upper = min(duration, end - offset)
        guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
        self.start = lower
        self.end = upper
    }
}
