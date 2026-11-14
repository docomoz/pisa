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
            if result.count == 3 { break }
            let selected = matches.indices.filter { NSIntersectionRange(matches[$0].range, target).length > 0 }
            guard let first = selected.first, let last = selected.last,
                  selected.count <= 3,
                  NSUnionRange(matches[first].range, matches[last].range) == target else { continue }
            // At a region edge, use its real audio boundary and three unique
            // words on the other side. Requiring two anchors on both sides
            // silently excluded the first and last words from every reread.
            // This only chooses audio; callers still require independent
            // agreement before changing any transcript text.
            if first < 2, last + 3 < source.count {
                let right = Array(sourceKeys[(last + 1)...(last + 3)])
                let found = occurrences(right)
                if found.count == 1, let index = found.first,
                   (first...(first + 4)).contains(index),
                   audioKeys.prefix(first).elementsEqual(sourceKeys.prefix(first)) {
                    let end = min(duration, words[index + 2].end + 0.5)
                    if (1...12).contains(end), !result.contains(0..<end) { result.append(0..<end) }
                }
                continue
            }
            let trailing = source.count - last - 1
            if trailing < 2, first >= 3 {
                let left = Array(sourceKeys[(first - 3)..<first])
                let found = occurrences(left)
                if found.count == 1, let index = found.first,
                   (trailing...(trailing + 4)).contains(words.count - index - 3),
                   audioKeys.suffix(trailing).elementsEqual(sourceKeys.suffix(trailing)) {
                    let start = max(0, words[index].start - 0.5)
                    if (1...12).contains(duration - start), !result.contains(start..<duration) { result.append(start..<duration) }
                }
                continue
            }
            guard first >= 2, last + 2 < source.count else { continue }
            // Adjacent words can share the same recognition error (a fused
            // name/preposition, for example). Search a bounded distance for
            // real, unique acoustic anchors instead of guessing timestamps.
            let left = (0...4).lazy.compactMap { gap -> (Int, Int)? in
                let end = first - gap
                guard end >= 2 else { return nil }
                return anchor(end >= 3 ? Array(sourceKeys[(end - 3)..<end]) : [],
                              fallback: Array(sourceKeys[(end - 2)..<end]))
            }.first
            let right = (0...4).lazy.compactMap { gap -> (Int, Int)? in
                let start = last + 1 + gap
                guard start + 1 < source.count else { return nil }
                return anchor(start + 2 < source.count ? Array(sourceKeys[start...(start + 2)]) : [],
                              fallback: Array(sourceKeys[start...(start + 1)]))
            }.first
            guard let left, let right else { continue }
            let gap = right.0 - (left.0 + left.1)
            guard (0...10).contains(gap) else { continue }
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
