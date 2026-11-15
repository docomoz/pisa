import Foundation

/// Retain the clean parts of sustained overlapping turns. The shared interval is
/// emitted once as unidentified speech instead of contaminating both full turns.
enum SpeakerTurnPartition {
    struct Turn {
        var range: Range<Int>
        var speaker: Int
    }
    struct Region {
        var range: Range<Int>
        var exclusions: [Range<Int>]
        var partitioned: Bool
    }

    static func partition(_ input: [Turn], sampleCount: Int, sampleRate: Int = 16_000) -> [Region] {
        guard sampleCount > 0, sampleRate > 0 else { return [] }
        let turns = input.compactMap { turn -> Turn? in
            let lower = max(0, turn.range.lowerBound), upper = min(sampleCount, turn.range.upperBound)
            return upper > lower ? Turn(range: lower..<upper, speaker: turn.speaker) : nil
        }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        var components: [[Turn]] = []
        var componentEnd = 0
        for turn in turns {
            if !components.isEmpty, turn.range.lowerBound < componentEnd {
                components[components.count - 1].append(turn)
                componentEnd = max(componentEnd, turn.range.upperBound)
            } else {
                components.append([turn])
                componentEnd = turn.range.upperBound
            }
        }
        return components.flatMap { component -> [Region] in
            let exclusions = component.map { turn in
                component.filter { $0.speaker != turn.speaker && $0.range.overlaps(turn.range) }.map(\.range)
            }
            let sustained = component.indices.map { index in
                SpeakerEmbeddingInput(range: component[index].range, exclusions: exclusions[index])
                    .hasSustainedOverlap(sampleCount: sampleCount, sampleRate: sampleRate)
            }
            let boundaries = Set(component.flatMap { [$0.range.lowerBound, $0.range.upperBound] }).sorted()
            let intervals = zip(boundaries, boundaries.dropFirst()).map { $0..<$1 }
            let active = intervals.map { interval in
                component.indices.filter { component[$0].range.overlaps(interval) }
            }
            // A tiny interjection may occupy all of its own short turn. Require
            // sustained competition for both voices before splitting a long turn.
            let needsPartition = active.contains { indices in
                Set(indices.filter { sustained[$0] }.map { component[$0].speaker }).count > 1
            }
            guard needsPartition else {
                return component.indices.map {
                    Region(range: component[$0].range, exclusions: exclusions[$0], partitioned: false)
                }
            }
            struct Piece {
                var range: Range<Int>
                var speaker: Int?
                var exclusions: [Range<Int>]
            }
            var result: [Piece] = []
            for (interval, indices) in zip(intervals, active) {
                let speakers = Set(indices.map { component[$0].speaker })
                guard !speakers.isEmpty else { continue }
                let speaker = speakers.count == 1 ? speakers.first : nil
                if let previous = result.last, previous.range.upperBound == interval.lowerBound,
                   previous.speaker == speaker {
                    result[result.count - 1].range = previous.range.lowerBound..<interval.upperBound
                    if speaker == nil { result[result.count - 1].exclusions = [result[result.count - 1].range] }
                } else {
                    result.append(Piece(range: interval, speaker: speaker, exclusions: speaker == nil ? [interval] : []))
                }
            }
            // The component can contain both sustained and brief overlaps. Keep
            // the existing brief-interjection tolerance at each resulting edge;
            // otherwise an unrelated sustained overlap creates new word cuts.
            var absorbed = true
            while absorbed {
                absorbed = false
                for index in result.indices where result[index].speaker == nil {
                    let mixed = result[index]
                    let candidates = [index - 1, index + 1].filter { neighbor in
                        guard result.indices.contains(neighbor), result[neighbor].speaker != nil else { return false }
                        let clean = result[neighbor]
                        let range = min(clean.range.lowerBound, mixed.range.lowerBound)..<max(clean.range.upperBound, mixed.range.upperBound)
                        return !SpeakerEmbeddingInput(range: range, exclusions: clean.exclusions + mixed.exclusions)
                            .hasSustainedOverlap(sampleCount: sampleCount, sampleRate: sampleRate)
                    }
                    guard let neighbor = candidates.max(by: { result[$0].range.count < result[$1].range.count }) else { continue }
                    result[neighbor].range = min(result[neighbor].range.lowerBound, mixed.range.lowerBound)..<max(result[neighbor].range.upperBound, mixed.range.upperBound)
                    result[neighbor].exclusions += mixed.exclusions
                    result.remove(at: index)
                    // The same local turn can now continue across its brief
                    // interjection. Pool only this contiguous clean interval.
                    var joined: [Piece] = []
                    for piece in result {
                        if let previous = joined.last, previous.speaker == piece.speaker,
                           previous.range.upperBound == piece.range.lowerBound {
                            joined[joined.count - 1].range = previous.range.lowerBound..<piece.range.upperBound
                            joined[joined.count - 1].exclusions += piece.exclusions
                        } else { joined.append(piece) }
                    }
                    result = joined
                    absorbed = true
                    break
                }
            }
            // A clean sliver shorter than the embedding minimum has no speaker
            // evidence and little ASR context. Retain its audio in the adjacent
            // unidentified span instead of decoding an isolated syllable.
            var joinedScrap = true
            while joinedScrap {
                joinedScrap = false
                for index in result.indices where result[index].speaker != nil && result[index].range.count < sampleRate * 3 / 2 {
                    let hasLeft = index > 0 && result[index - 1].speaker == nil
                    let hasRight = index + 1 < result.count && result[index + 1].speaker == nil
                    guard hasLeft || hasRight else { continue }
                    let first = hasLeft ? index - 1 : index
                    let last = hasRight ? index + 1 : index
                    let range = result[first].range.lowerBound..<result[last].range.upperBound
                    result.replaceSubrange(first...last, with: [Piece(range: range, speaker: nil, exclusions: [range])])
                    joinedScrap = true
                    break
                }
            }
            return result.map {
                Region(range: $0.range, exclusions: $0.exclusions, partitioned: true)
            }
        }
    }
}
