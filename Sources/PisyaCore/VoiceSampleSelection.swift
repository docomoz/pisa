import Foundation

/// The first transcript segment anchors each voice group across renames.
func voiceGroupAnchors(in segments: [TranscriptSegment]) -> [TranscriptSegment] {
    var seen = Set<String>()
    return segments.filter { $0.speaker != TranscriptSegment.unidentifiedSpeaker && seen.insert($0.speaker).inserted }
}

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

/// Retain only audio within the preview of the reply the user selected.
func automaticVoiceSample(for segmentID: UUID, in meeting: Meeting, audioDurations: [String: Double]? = nil) -> TranscriptSegment? {
    guard var sample = meeting.segments.first(where: { $0.id == segmentID }),
          sample.start.isFinite, sample.end.isFinite, sample.start >= 0, sample.end > sample.start,
          !sample.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let filename = sample.audioFile ?? meeting.audioFiles.first(where: {
              sample.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.")
          }) ?? meeting.audioFiles.first,
          meeting.audioFiles.contains(filename) else { return nil }
    let offset = meeting.audioOffsets[filename] ?? 0
    guard offset.isFinite else { return nil }

    var end = min(sample.end, sample.start + 8)
    if let audioDurations {
        guard let duration = audioDurations[filename], duration.isFinite, duration > 0 else { return nil }
        end = min(end, offset + duration)
    }
    let start = max(sample.start, offset)
    guard end - start >= 2 else { return nil }

    let interruptions = meeting.segments.filter {
        $0.speaker != sample.speaker && $0.start.isFinite && $0.end.isFinite &&
            $0.end > $0.start && $0.end > start && $0.start < end
    }.sorted { $0.start < $1.start }
    var cursor = start
    var intervals: [Range<Double>] = []
    for other in interruptions where other.end > cursor {
        let gapEnd = other.start - 0.15
        if gapEnd > cursor { intervals.append(cursor..<gapEnd) }
        cursor = max(cursor, other.end + 0.15)
    }
    if cursor < end { intervals.append(cursor..<end) }
    // Prefer the earliest interval on a tie.
    guard let best = intervals.max(by: { $0.upperBound - $0.lowerBound < $1.upperBound - $1.lowerBound }),
          best.upperBound - best.lowerBound >= 2 else { return nil }
    sample.start = best.lowerBound
    sample.end = best.upperBound
    sample.audioFile = filename
    sample.embedding = nil
    return sample
}
