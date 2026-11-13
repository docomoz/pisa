import Foundation

/// Finds audio using uniquely matched surrounding words, never proportional text positions.
enum RecognitionAudioFocus {
    private static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?"#)
    private static func key(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "ё", with: "е").replacingOccurrences(of: "’", with: "'")
    }

    static func ranges(original: String, targets: [Range<String.Index>], words: [RecognitionTimedWord], duration: Double) -> [Range<Double>] {
        guard duration.isFinite, duration >= 1, !words.isEmpty,
              words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.end <= duration }),
              zip(words, words.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { return [] }
        let matches = pattern.matches(in: original, range: NSRange(original.startIndex..., in: original))
        let source = matches.compactMap { Range($0.range, in: original) }
        let sourceKeys = source.map { key(String(original[$0])) }
        let audioKeys = words.map { key($0.text) }
        let targetRanges = targets.map { NSRange($0, in: original) }
        guard targetRanges.allSatisfy({ $0.location != NSNotFound && $0.length > 0 }),
              !targetRanges.indices.contains(where: { i in targetRanges.indices.contains(where: { j in i < j && NSIntersectionRange(targetRanges[i], targetRanges[j]).length > 0 }) }) else { return [] }
        func occurrences(_ sequence: [String]) -> [Int] {
            guard sequence.count <= audioKeys.count else { return [] }
            return (0...(audioKeys.count - sequence.count)).filter { audioKeys[$0..<($0 + sequence.count)].elementsEqual(sequence) }
        }
        func anchor(_ preferred: [String], fallback: [String]) -> (Int, Int)? {
            if preferred.count == 3 {
                let found = occurrences(preferred)
                if found.count > 1 { return nil }
                if let index = found.first { return (index, 3) }
            }
            let found = occurrences(fallback)
            guard found.count == 1, let index = found.first else { return nil }
            return (index, 2)
        }
        var result: [Range<Double>] = []
        for target in targetRanges {
            let selected = matches.indices.filter { NSIntersectionRange(matches[$0].range, target).length > 0 }
            guard let first = selected.first, let last = selected.last,
                  selected.count <= 3, first >= 2, last + 2 < source.count,
                  NSUnionRange(matches[first].range, matches[last].range) == target else { continue }
            let left2 = Array(sourceKeys[(first - 2)..<first])
            let right2 = Array(sourceKeys[(last + 1)...(last + 2)])
            let left3 = first >= 3 ? Array(sourceKeys[(first - 3)..<first]) : []
            let right3 = last + 3 < source.count ? Array(sourceKeys[(last + 1)...(last + 3)]) : []
            guard let left = anchor(left3, fallback: left2), let right = anchor(right3, fallback: right2) else { continue }
            let gap = right.0 - (left.0 + left.1)
            guard (0...4).contains(gap) else { continue }
            let start = max(0, words[left.0].start - 0.5)
            let end = min(duration, words[right.0 + right.1 - 1].end + 0.5)
            guard end - start >= 1, end - start <= 12 else { continue }
            let interval = start..<end
            if !result.contains(interval) { result.append(interval) }
            if result.count == 3 { break }
        }
        return result
    }
}
