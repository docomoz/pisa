import Foundation

/// Reliable turns establish meeting-wide voices; weaker evidence cannot bridge distinct voices.
public enum SpeakerClustering {
    public static func assign(_ input: [TranscriptSegment], profiles: [VoiceProfile], threshold: Float = 0.55) -> [TranscriptSegment] {
        struct Anchor {
            var index: Int
            var vector: [Float]
            var duration: Double
            var start: Double
            var end: Double
        }
        struct Cluster {
            var sum: [Float]
            var anchors: [Anchor]
            var knownNames: Set<String>

            var independentAnchors: [Anchor] {
                var end = -Double.infinity
                var seen = Set<[Float]>()
                return anchors.sorted { $0.end == $1.end ? $0.index < $1.index : $0.end < $1.end }.filter { anchor in
                    guard anchor.start >= end, seen.insert(anchor.vector).inserted else { return false }
                    end = anchor.end
                    return true
                }
            }

            func supports(_ vector: [Float], duration: Double, threshold: Float) -> Bool {
                let scores = anchors.map { anchor -> (Float, Float) in
                    let floor: Float = duration >= 4.5 && anchor.duration >= 4.5
                        ? threshold : min(threshold, 0.35)
                    return (VoiceMatcher.similarity(vector, anchor.vector), floor)
                }
                // A mature cluster needs support from most independent turns,
                // not unanimity across every noisy excerpt. Strong acoustic
                // contradictions remain a veto; small groups retain all-pairs.
                guard scores.allSatisfy({ $0.0 >= min($0.1, 0.35) }) else { return false }
                let independent = independentAnchors
                guard independent.count >= 6 else { return scores.allSatisfy { $0.0 >= $0.1 } }
                let supporting = independent.filter { anchor in
                    let floor: Float = duration >= 4.5 && anchor.duration >= 4.5 ? threshold : min(threshold, 0.35)
                    return VoiceMatcher.similarity(vector, anchor.vector) >= floor
                }
                return supporting.count >= Int(ceil(Double(independent.count) * 0.6))
            }
        }
        func normalized(_ vector: [Float]?) -> [Float]? {
            guard let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
            let length = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
            return length.isFinite && length > 0.0001 ? vector.map { $0 / length } : nil
        }
        let vectors = input.map { $0.speaker == "Я" || $0.speakerEvidenceIsMixed == true ? nil : normalized($0.embedding) }
        let durations = input.map { segment -> Double in
            let turn = segment.end - segment.start
            guard let evidence = segment.embeddingDuration else { return turn }
            return evidence.isFinite && evidence > 0 ? min(turn, evidence) : 0
        }
        let matcher = VoiceMatcher(profiles: profiles)
        let known = vectors.map { $0.flatMap { matcher.identify($0) } }
        let anchors = input.indices.filter { durations[$0] >= 2.5 && vectors[$0] != nil }
        var clusters: [Cluster] = []
        var membership: [Int: Int] = [:]
        for index in anchors.sorted(by: { durations[$0] > durations[$1] }) {
            guard let vector = vectors[index] else { continue }
            let weight = Float(min(10, durations[index]))
            let anchor = Anchor(index: index, vector: vector, duration: durations[index], start: input[index].start, end: input[index].end)
            var best: Int?
            var bestScore = threshold
            for cluster in clusters.indices {
                let score = VoiceMatcher.similarity(vector, clusters[cluster].sum)
                guard score >= bestScore else { continue }
                if let name = known[index], !clusters[cluster].knownNames.isEmpty,
                   !clusters[cluster].knownNames.contains(name) { continue }
                // A mixed turn can be close to two clean voices. Compare their
                // individual evidence before allowing it to join those voices.
                guard clusters[cluster].supports(vector, duration: durations[index], threshold: threshold) else { continue }
                best = cluster
                bestScore = score
            }
            if let best {
                for i in vector.indices { clusters[best].sum[i] += vector[i] * weight }
                clusters[best].anchors.append(anchor)
                if let name = known[index] { clusters[best].knownNames.insert(name) }
                membership[index] = best
            } else {
                membership[index] = clusters.count
                clusters.append(Cluster(sum: vector.map { $0 * weight },
                    anchors: [anchor], knownNames: Set(known[index].map { [$0] } ?? [])))
            }
        }
        // Reconcile fragments only after enough independent evidence exists.
        // Keep the same centroid threshold and a lower contradiction veto.
        var merged = true
        while merged {
            merged = false
            outer: for a in clusters.indices {
                for b in clusters.indices where b > a {
                    let left = clusters[a], right = clusters[b]
                    guard left.sum.count == right.sum.count,
                          left.knownNames.union(right.knownNames).count <= 1,
                          VoiceMatcher.similarity(left.sum, right.sum) >= threshold,
                          left.independentAnchors.count + right.independentAnchors.count >= 6 else { continue }
                    func reciprocalSupport(_ first: Cluster, _ second: Cluster) -> Bool {
                        first.anchors.allSatisfy { anchor in
                            second.supports(anchor.vector, duration: anchor.duration, threshold: threshold)
                        }
                    }
                    guard reciprocalSupport(left, right), reciprocalSupport(right, left) else { continue }
                    for index in clusters[a].sum.indices { clusters[a].sum[index] += clusters[b].sum[index] }
                    clusters[a].anchors += clusters[b].anchors
                    clusters[a].knownNames.formUnion(clusters[b].knownNames)
                    clusters.remove(at: b)
                    for index in membership.keys {
                        if membership[index] == b { membership[index] = a }
                        else if let current = membership[index], current > b { membership[index] = current - 1 }
                    }
                    merged = true
                    break outer
                }
            }
        }
        // A name belongs to a coherent voice, not just to the clearest phrase.
        // Require independent turns and corroborated enrollment (or repeated
        // direct recognition), and never propagate conflicting named evidence.
        let clusterNames: [String?] = clusters.map { cluster in
            guard cluster.knownNames.count <= 1,
                  let name = matcher.identify(cluster.sum),
                  cluster.knownNames.isEmpty || cluster.knownNames.contains(name) else { return nil }
            let corroboratedProfile = matcher.identify(cluster.sum, requiringCorroboration: true) == name
            let evidence = cluster.anchors.filter { corroboratedProfile || known[$0.index] == name }
            let independentPair = evidence.contains { first in
                evidence.contains { second in
                    first.index != second.index && first.vector != second.vector &&
                    (input[first.index].end <= input[second.index].start || input[second.index].end <= input[first.index].start) &&
                    first.duration + second.duration >= 6
                }
            }
            return independentPair ? name : nil
        }
        var result = input, names: [Int: String] = [:]
        var reservedNames = Set(profiles.map(\.name))
        var nextAnonymous = 1
        for i in input.indices {
            if input[i].speakerEvidenceIsMixed == true {
                result[i].speaker = TranscriptSegment.unidentifiedSpeaker
                continue
            }
            guard let vector = vectors[i] else { continue }
            if let name = known[i] { result[i].speaker = name; continue }
            let ranked = clusters.indices.compactMap { cluster -> (Int, Float)? in
                let score = VoiceMatcher.similarity(vector, clusters[cluster].sum)
                guard score >= threshold, clusters[cluster].supports(vector, duration: durations[i], threshold: threshold) else { return nil }
                return (cluster, score)
            }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first,
                  membership[i].map({ $0 == best.0 }) ?? true,
                  ranked.count == 1 || best.1 - ranked[1].1 >= 0.04 else { result[i].speaker = TranscriptSegment.unidentifiedSpeaker; continue }
            if let name = clusterNames[best.0] {
                result[i].speaker = matcher.supportsInheritedName(name, embedding: vector)
                    ? name : TranscriptSegment.unidentifiedSpeaker
                continue
            }
            if names[best.0] == nil {
                while reservedNames.contains("Спикер \(nextAnonymous)") { nextAnonymous += 1 }
                let name = "Спикер \(nextAnonymous)"
                names[best.0] = name
                reservedNames.insert(name)
                nextAnonymous += 1
            }
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
