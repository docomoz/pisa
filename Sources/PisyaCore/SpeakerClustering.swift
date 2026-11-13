import Foundation

/// Reliable turns establish meeting-wide voices; weaker evidence cannot bridge distinct voices.
public enum SpeakerClustering {
    public static func assign(_ input: [TranscriptSegment], profiles: [VoiceProfile], threshold: Float = 0.55) -> [TranscriptSegment] {
        struct Cluster {
            var sum: [Float]
            var anchors: [(vector: [Float], duration: Double)]

            func supports(_ vector: [Float], duration: Double, threshold: Float) -> Bool {
                anchors.allSatisfy { anchor in
                    // Short turns produce noisier vectors. Keep their strong
                    // contradictions, without giving every variation a veto.
                    // Turn duration is a conservative proxy: overlap exclusion
                    // can shorten the actual audio used for an embedding.
                    let floor: Float = duration >= 4.5 && anchor.duration >= 4.5
                        ? threshold : min(threshold, 0.35)
                    return VoiceMatcher.similarity(vector, anchor.vector) >= floor
                }
            }
        }
        func normalized(_ vector: [Float]?) -> [Float]? {
            guard let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
            let length = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
            return length.isFinite && length > 0.0001 ? vector.map { $0 / length } : nil
        }
        let vectors = input.map { $0.speaker == "Я" ? nil : normalized($0.embedding) }
        let durations = input.map { $0.end - $0.start }
        let anchors = input.indices.filter { durations[$0] >= 2.5 && vectors[$0] != nil }
        var clusters: [Cluster] = []
        var membership: [Int: Int] = [:]
        for index in anchors.sorted(by: { durations[$0] > durations[$1] }) {
            guard let vector = vectors[index] else { continue }
            let weight = Float(min(10, durations[index]))
            var best: Int?
            var bestScore = threshold
            for cluster in clusters.indices {
                let score = VoiceMatcher.similarity(vector, clusters[cluster].sum)
                guard score >= bestScore else { continue }
                // A mixed turn can be close to two clean voices. Compare their
                // individual evidence before allowing it to join those voices.
                guard clusters[cluster].supports(vector, duration: durations[index], threshold: threshold) else { continue }
                best = cluster
                bestScore = score
            }
            if let best {
                for i in vector.indices { clusters[best].sum[i] += vector[i] * weight }
                clusters[best].anchors.append((vector, durations[index]))
                membership[index] = best
            } else {
                membership[index] = clusters.count
                clusters.append(Cluster(sum: vector.map { $0 * weight }, anchors: [(vector, durations[index])]))
            }
        }
        let matcher = VoiceMatcher(profiles: profiles)
        var result = input, names: [Int: String] = [:]
        for i in input.indices {
            guard let vector = vectors[i] else { continue }
            if let known = matcher.identify(vector) { result[i].speaker = known; continue }
            let ranked = clusters.indices.compactMap { cluster -> (Int, Float)? in
                let score = VoiceMatcher.similarity(vector, clusters[cluster].sum)
                guard score >= threshold, clusters[cluster].supports(vector, duration: durations[i], threshold: threshold) else { return nil }
                return (cluster, score)
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first,
                  membership[i].map({ $0 == best.0 }) ?? true,
                  ranked.count == 1 || best.1 - ranked[1].1 >= 0.04 else { result[i].speaker = TranscriptSegment.unidentifiedSpeaker; continue }
            if names[best.0] == nil { names[best.0] = "Спикер \(names.count + 1)" }
            result[i].speaker = names[best.0]!
        }
        return result
    }
}

/// Enrollment rejects sustained competing speech, not brief interference or
/// missing diarization evidence. The latter is an abstention by the model.
enum SpeakerSampleQuality {
    static func hasSustainedConflict(_ activity: [(speaker: Int, start: Double, end: Double)]) -> Bool {
        var durations: [Int: Double] = [:]
        for (speaker, turns) in Dictionary(grouping: activity, by: \.speaker) {
            let ranges = turns.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
                .sorted { $0.start < $1.start }
            var end = -Double.infinity
            for turn in ranges {
                durations[speaker, default: 0] += max(0, turn.end - max(turn.start, end))
                end = max(end, turn.end)
            }
        }
        guard let dominant = durations.values.max(), dominant > 0 else { return false }
        let competing = durations.values.reduce(0, +) - dominant
        // A short interjection/noise event must not disable an otherwise useful
        // voice. Bound tolerance both relatively and in absolute time.
        let tolerance = min(1.5, dominant * 0.20)
        return competing > tolerance
    }
}
