import Foundation

/// Recover speaker evidence when the segmentation model abstains on audible speech.
/// Independent excerpts must agree; uncertain audio never bridges two voices.
enum SpeakerRecovery {
    struct Evidence {
        var range: Range<Int>
        var vector: [Float]?
        var probes: [[Float]] = []
    }

    static func recognitionRange(for range: Range<Int>, in gap: Range<Int>, padding: Int) -> Range<Int> {
        max(gap.lowerBound, range.lowerBound - padding)..<min(gap.upperBound, range.upperBound + padding)
    }

    static func recover(in samples: [Float], range: Range<Int>, sampleRate: Int = 16_000,
                        embedding: (Range<Int>) -> [Float]?) -> [Evidence] {
        let minimum = sampleRate * 3
        func evaluate(_ range: Range<Int>) -> [Evidence] {
            guard range.count >= minimum else { return [Evidence(range: range, vector: nil)] }
            let middle = range.lowerBound + range.count / 2
            let left = range.lowerBound..<middle, right = middle..<range.upperBound
            let probes = [embedding(left), embedding(right)]
            if let vector = coherentEmbedding(probes) {
                return [Evidence(range: range, vector: vector, probes: probes.compactMap { normalized($0) })]
            }
            // A change of voice inside a probe is not a reason to discard both
            // speakers. Recheck each half only with its own independent audio.
            if left.count >= minimum, right.count >= minimum {
                let lower = max(range.lowerBound + minimum, middle - sampleRate / 2)
                let upper = min(range.upperBound - minimum, middle + sampleRate / 2)
                let cut = upper > lower
                    ? SpeechChunking.quietBoundary(in: samples, search: lower..<upper, sampleRate: sampleRate)
                    : middle
                return evaluate(range.lowerBound..<cut) + evaluate(cut..<range.upperBound)
            }
            return [Evidence(range: range, vector: nil)]
        }
        let evidence = ranges(in: samples, range: range, sampleRate: sampleRate).flatMap(evaluate)
        return group(evidence, maximumSamples: sampleRate * 24)
    }

    static func ranges(in samples: [Float], range: Range<Int>, sampleRate: Int = 16_000) -> [Range<Int>] {
        guard sampleRate > 0, range.lowerBound >= 0, range.upperBound <= samples.count,
              !range.isEmpty else { return [] }
        let minimum = sampleRate * 3
        let count = max(1, min(Int(ceil(Double(range.count) / Double(sampleRate * 6))), range.count / minimum))
        guard count > 1 else { return [range] }
        var result: [Range<Int>] = []
        var cursor = range.lowerBound
        for index in 1..<count {
            let target = range.lowerBound + range.count * index / count
            let lower = max(cursor + minimum, target - sampleRate / 2)
            let upper = min(range.upperBound - minimum * (count - index), target + sampleRate / 2)
            let cut = upper > lower
                ? SpeechChunking.quietBoundary(in: samples, search: lower..<upper, sampleRate: sampleRate)
                : lower
            result.append(cursor..<cut)
            cursor = cut
        }
        result.append(cursor..<range.upperBound)
        return result
    }

    static func coherentEmbedding(_ parts: [[Float]?], threshold: Float = 0.55) -> [Float]? {
        guard parts.count >= 2 else { return nil }
        let vectors = parts.compactMap { normalized($0) }
        guard vectors.count == parts.count, let first = vectors.first,
              vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        for index in vectors.indices {
            for other in vectors.indices where other > index {
                guard VoiceMatcher.similarity(vectors[index], vectors[other]) >= threshold else { return nil }
            }
        }
        return normalized(vectors.reduce([Float](repeating: 0, count: first.count)) { sum, vector in
            zip(sum, vector).map(+)
        })
    }

    static func group(_ evidence: [Evidence], maximumSamples: Int, threshold: Float = 0.55) -> [Evidence] {
        struct Group {
            var range: Range<Int>
            var parts: [Evidence]
        }
        var groups: [Group] = []
        for item in evidence {
            let candidate = Evidence(range: item.range, vector: normalized(item.vector), probes: item.probes)
            if let previous = groups.last,
               previous.range.upperBound == candidate.range.lowerBound,
               candidate.range.upperBound - previous.range.lowerBound <= maximumSamples {
                let sameVoice = previous.parts.allSatisfy { part in
                    switch (part.vector, candidate.vector) {
                    case (nil, nil): return true
                    case let (left?, right?):
                        let leftProbes = part.probes.isEmpty ? [left] : part.probes
                        let rightProbes = candidate.probes.isEmpty ? [right] : candidate.probes
                        return leftProbes.allSatisfy { a in
                            rightProbes.allSatisfy { b in VoiceMatcher.similarity(a, b) >= threshold }
                        }
                    default: return false
                    }
                }
                if sameVoice {
                    groups[groups.count - 1].range = previous.range.lowerBound..<candidate.range.upperBound
                    groups[groups.count - 1].parts.append(candidate)
                    continue
                }
            }
            groups.append(Group(range: candidate.range, parts: [candidate]))
        }
        return groups.map { group in
            guard let first = group.parts.first?.vector else { return Evidence(range: group.range, vector: nil) }
            var sum = [Float](repeating: 0, count: first.count)
            for part in group.parts {
                guard let vector = part.vector else { continue }
                for index in sum.indices { sum[index] += vector[index] * Float(part.range.count) }
            }
            return Evidence(range: group.range, vector: normalized(sum), probes: group.parts.flatMap(\.probes))
        }
    }

    private static func normalized(_ vector: [Float]?) -> [Float]? {
        guard let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0.0001 else { return nil }
        return vector.map { $0 / norm }
    }
}
