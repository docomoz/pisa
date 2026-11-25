import Foundation

/// Remove shared decoding context only when independently timed audio proves
/// that two boundary tokens refer to one physical word crossing the same cut.
enum RecognitionBoundaryOverlap {
    private static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)?"#)

    private static func matches(_ text: String) -> [NSTextCheckingResult] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func canonical(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping.lowercased()
    }
    private static func token(_ match: NSTextCheckingResult, in text: String) -> String {
        canonical((text as NSString).substring(with: match.range))
    }
    // Acoustic decoding can omit ё before final transcript spelling is applied.
    // Only dictionary forms without a competing е spelling are interchangeable.
    private static func sameAcousticWord(_ lhs: String, _ rhs: String) -> Bool {
        let a = canonical(lhs), b = canonical(rhs)
        if a == b { return true }
        guard a.contains("ё") || b.contains("ё"),
              a.replacingOccurrences(of: "ё", with: "е") == b.replacingOccurrences(of: "ё", with: "е") else { return false }
        let firstSpelling = TranscriptOrthography.yoSpelling(for: a[...]) ?? a
        let secondSpelling = TranscriptOrthography.yoSpelling(for: b[...]) ?? b
        return firstSpelling == secondSpelling
    }

    static func candidate(left: String, right: String) -> String? {
        let a = matches(left), b = matches(right)
        guard a.count >= 2, b.count >= 2, let last = a.last, let first = b.first else { return nil }
        let word = token(last, in: left)
        // Preserve terse confirmations and stutters even if the acoustic model
        // collapses their repetitions. Their cost is lower than deleting speech.
        guard word.count >= 4, word.allSatisfy(\.isLetter), token(first, in: right) == word,
              let leftRange = Range(last.range, in: left), let rightRange = Range(first.range, in: right),
              let secondRange = Range(b[1].range, in: right) else { return nil }
        let dashes: Set<Character> = ["-", "‐", "‑", "‒", "–", "—"]
        func touchesCompound(_ range: Range<String.Index>, in text: String) -> Bool {
            (range.lowerBound > text.startIndex && dashes.contains(text[text.index(before: range.lowerBound)])) ||
            (range.upperBound < text.endIndex && dashes.contains(text[range.upperBound]))
        }
        guard !touchesCompound(leftRange, in: left), !touchesCompound(rightRange, in: right) else { return nil }
        // Removing a word must not leave the rest of a quotation or parenthesis
        // without its opening delimiter. A fully quoted single token is safe.
        let prefix = right[..<rightRange.lowerBound]
        let following = right[rightRange.upperBound..<secondRange.lowerBound]
        let pairs: [(Character, Character)] = [("«", "»"), ("“", "”"), ("\"", "\""), ("(", ")"), ("[", "]"), ("{", "}")]
        guard pairs.allSatisfy({ prefix.contains($0.0) == following.contains($0.1) }) else { return nil }
        return word
    }

    static func revisedRight(left: String, right: String, leftWords: [RecognitionTimedWord],
                             rightWords: [RecognitionTimedWord], unionWords: [RecognitionTimedWord],
                             cut: Double, sharedAudio: Range<Double>) -> String? {
        guard let word = candidate(left: left, right: right), cut.isFinite,
              sharedAudio.lowerBound.isFinite, sharedAudio.upperBound.isFinite,
              sharedAudio.lowerBound < cut, sharedAudio.upperBound > cut,
              leftWords.count >= 2, rightWords.count >= 2,
              let a = leftWords.last, let b = rightWords.first else { return nil }
        guard sameAcousticWord(a.text, word), sameAcousticWord(b.text, word) else { return nil }
        func overlaps(_ token: RecognitionTimedWord, _ range: Range<Double>) -> Bool {
            token.start.isFinite && token.end.isFinite && token.end > token.start &&
            token.start < range.upperBound && token.end > range.lowerBound
        }
        guard overlaps(a, sharedAudio), overlaps(b, sharedAudio) else { return nil }
        let neighborhood = min(a.start, b.start)..<max(a.end, b.end)
        let occurrences = unionWords.indices.filter {
            overlaps(unionWords[$0], neighborhood) && sameAcousticWord(unionWords[$0].text, word)
        }
        guard occurrences.count == 1, let index = occurrences.first,
              index > 0, index + 1 < unionWords.count else { return nil }
        let actual = unionWords[index]
        guard actual.start < cut, actual.end > cut,
              overlaps(a, actual.start..<actual.end), overlaps(b, actual.start..<actual.end),
              sameAcousticWord(unionWords[index - 1].text, leftWords[leftWords.count - 2].text),
              sameAcousticWord(unionWords[index + 1].text, rightWords[1].text) else { return nil }
        guard let first = matches(right).first, let range = Range(first.range, in: right) else { return nil }
        var suffix = right[range.upperBound...]
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.!?—–-»”\")]}"))
        while let scalar = suffix.unicodeScalars.first, separators.contains(scalar) {
            suffix = suffix.dropFirst()
        }
        return suffix.isEmpty ? nil : String(suffix)
    }
}
