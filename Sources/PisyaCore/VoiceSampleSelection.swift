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

/// The sample to retain when assigning a participant's name.
func automaticVoiceSample(for segmentID: UUID, in meeting: Meeting, allMatching: Bool, audioDurations: [String: Double]? = nil) -> TranscriptSegment? {
    guard let selected = meeting.segments.first(where: { $0.id == segmentID }), !meeting.audioFiles.isEmpty else { return nil }
    let interruptions = meeting.segments.filter {
        $0.speaker != selected.speaker && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
    }.sorted { $0.start < $1.start }
    var best: TranscriptSegment?
    for segment in meeting.segments where allMatching ? segment.speaker == selected.speaker : segment.id == selected.id {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start,
              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let embedding = segment.embedding, !embedding.isEmpty,
              embedding.allSatisfy({ $0.isFinite }), embedding.contains(where: { $0 != 0 }),
              let filename = segment.audioFile ?? meeting.audioFiles.first(where: { segment.speaker == "Я" ? $0.contains("-mic.") : $0.contains("-remote.") }) ?? meeting.audioFiles.first,
              meeting.audioFiles.contains(filename) else { continue }
        let offset = meeting.audioOffsets[filename] ?? 0
        guard offset.isFinite else { continue }
        var end = segment.end
        if let audioDurations {
            guard let duration = audioDurations[filename], duration.isFinite, duration > 0 else { continue }
            end = min(end, offset + duration)
        }
        var cursor = max(segment.start, offset)
        var intervals: [(Double, Double)] = []
        for other in interruptions where other.end > cursor && other.start < end {
            if other.start > cursor { intervals.append((cursor, min(end, other.start - 0.15))) }
            cursor = max(cursor, other.end + 0.15)
        }
        intervals.append((cursor, end))
        for (start, end) in intervals where end - start >= 2 {
            let duration = min(8, end - start)
            var candidate = segment
            candidate.start = start + (end - start - duration) / 2
            candidate.end = candidate.start + duration
            candidate.audioFile = filename
            if let previous = best {
                let previousDuration = previous.end - previous.start
                if duration < previousDuration || (duration == previousDuration && candidate.start >= previous.start) { continue }
            }
            best = candidate
        }
    }
    return best
}
