import Foundation

/// Keep the voice picker compact while offering the longest available speech.
func voiceSamples(for speaker: String, in segments: [TranscriptSegment]) -> [TranscriptSegment] {
    let ranked = segments.enumerated().filter { _, segment in
        segment.speaker == speaker && segment.start.isFinite && segment.end.isFinite
            && segment.start >= 0 && segment.end > segment.start
    }.sorted { lhs, rhs in
        let leftDuration = lhs.element.end - lhs.element.start
        let rightDuration = rhs.element.end - rhs.element.start
        if leftDuration != rightDuration { return leftDuration > rightDuration }
        if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
        return lhs.offset < rhs.offset
    }
    // Two seconds is also the minimum for saving a voice sample. A lone short
    // fallback keeps speakers with only brief replies available for naming.
    let usable = ranked.filter { $0.element.end - $0.element.start >= 2 }
    let selected = usable.isEmpty ? Array(ranked.prefix(1)) : Array(usable.prefix(2))
    return selected.sorted { lhs, rhs in
        if lhs.element.start != rhs.element.start { return lhs.element.start < rhs.element.start }
        return lhs.offset < rhs.offset
    }.map(\.element)
}
