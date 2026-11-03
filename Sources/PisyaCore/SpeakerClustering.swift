import Foundation

/// Meeting-wide centroids: reliable turns establish voices; short turns only match them.
public enum SpeakerClustering {
    public static func assign(_ input: [TranscriptSegment], profiles: [VoiceProfile], threshold: Float = 0.55) -> [TranscriptSegment] {
        struct Cluster { var sum: [Float]; var weight: Float }
        func normalized(_ vector: [Float]?) -> [Float]? {
            guard let vector, !vector.isEmpty, vector.allSatisfy(\.isFinite) else { return nil }
            let length = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
            return length > 0.0001 ? vector.map { $0 / length } : nil
        }
        var clusters: [Cluster] = []
        let candidates = input.indices.filter { input[$0].speaker != "Я" && normalized(input[$0].embedding) != nil }
        // Longest regions give more stable initial evidence than arbitrary file order.
        for index in candidates.sorted(by: { input[$0].end - input[$0].start > input[$1].end - input[$1].start }) {
            let segment = input[index]
            guard segment.end - segment.start >= 2.5, let vector = normalized(segment.embedding) else { continue }
            let weight = Float(min(10, segment.end - segment.start))
            if let best = clusters.indices.max(by: { VoiceMatcher.similarity(vector, clusters[$0].sum) < VoiceMatcher.similarity(vector, clusters[$1].sum) }),
               VoiceMatcher.similarity(vector, clusters[best].sum) >= threshold {
                for i in vector.indices { clusters[best].sum[i] += vector[i] * weight }
                clusters[best].weight += weight
            } else { clusters.append(Cluster(sum: vector.map { $0 * weight }, weight: weight)) }
        }
        // Reconcile clusters whose centroids converged as more evidence accumulated.
        var merged = true
        while merged {
            merged = false
            outer: for a in clusters.indices {
                for b in clusters.indices where b > a {
                    if VoiceMatcher.similarity(clusters[a].sum, clusters[b].sum) >= threshold {
                        for i in clusters[a].sum.indices { clusters[a].sum[i] += clusters[b].sum[i] }
                        clusters[a].weight += clusters[b].weight; clusters.remove(at: b)
                        merged = true; break outer
                    }
                }
            }
        }
        var result = input, names: [Int: String] = [:]
        for i in input.indices {
            guard input[i].speaker != "Я", let vector = normalized(input[i].embedding) else { continue }
            if let known = VoiceMatcher.identify(vector, profiles: profiles) { result[i].speaker = known; continue }
            let ranked = clusters.indices.map { ($0, VoiceMatcher.similarity(vector, clusters[$0].sum)) }.sorted { $0.1 > $1.1 }
            guard let best = ranked.first, best.1 >= threshold,
                  ranked.count == 1 || best.1 - ranked[1].1 >= 0.04 else { result[i].speaker = "Собеседники"; continue }
            if names[best.0] == nil { names[best.0] = "Спикер \(names.count + 1)" }
            result[i].speaker = names[best.0]!
        }
        return result
    }
}
