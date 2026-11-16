import Foundation

/// A boundary repair requires agreement from full-context acoustic and language
/// decodes. Spelling similarity between the two damaged fragments is never used.
enum RecognitionBoundaryRepair {
    struct Probe {
        let left: String
        let right: String
        let leftAnchor: String
        let rightAnchor: String
        let word: String
        let observed: [RecognitionTimedWord]
        let cut: Double
        let sharedAudio: Range<Double>
    }
    struct Proposal {
        let probe: Probe
        let word: RecognitionTimedWord
    }
    struct Revision {
        let left: String
        let right: String
    }

    private struct Token {
        let raw: String
        let canonical: String
        let range: Range<String.Index>
    }
    private struct Text {
        let source: String
        let tokens: [Token]
        init(_ source: String) {
            self.source = source
            tokens = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                guard let range = Range(match.range, in: source) else { return nil }
                let raw = String(source[range])
                return Token(raw: raw, canonical: normalize(raw), range: range)
            }
        }
        func safeBoundary(_ token: Token) -> Bool {
            guard token.canonical.count >= 4, token.canonical.allSatisfy(\.isLetter) else { return false }
            let attached: Set<Character> = ["-", "‐", "‑", "‒", "–", "—", "«", "»", "“", "”", "\"", "'", "‘", "’", "„", "‟", "(", ")", "[", "]", "{", "}"]
            if token.range.lowerBound > source.startIndex,
               attached.contains(source[source.index(before: token.range.lowerBound)]) { return false }
            if token.range.upperBound < source.endIndex, attached.contains(source[token.range.upperBound]) { return false }
            return true
        }
    }
    private static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}]*(?:['’][\p{L}\p{M}\p{N}]+)?"#)
    // An actually heard short word must not become a "clipped prefix" merely
    // because the next longer word starts with the same letters.
    private static let completeShortWords: Set<String> = [
        "а", "и", "я", "в", "к", "с", "у", "о", "да", "ну", "не", "ни", "но", "мы", "вы", "он", "ты",
        "по", "на", "за", "от", "до", "из", "об", "во", "со", "ко", "то", "та", "те", "же", "ли", "бы", "уж",
        "ей", "её", "ее", "ею", "им", "их",
        "эх", "ах", "ох", "ой", "ай", "эй", "ок", "a", "i", "ok"
    ]
    private static func normalize(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }
    private static func overlaps(_ word: RecognitionTimedWord, _ range: Range<Double>) -> Bool {
        word.start.isFinite && word.end.isFinite && word.end > word.start &&
        word.start < range.upperBound && word.end > range.lowerBound
    }

    /// Interleaved microphone speech must not hide an adjacent remote cut. Every
    /// turn updates its own file's predecessor, including non-recovered turns.
    static func adjacentPairs(_ segments: [TranscriptSegment]) -> [(left: Int, right: Int)] {
        var previous: [String: Int] = [:]
        var result: [(left: Int, right: Int)] = []
        for index in segments.indices {
            guard let file = segments[index].audioFile else { continue }
            if let left = previous[file] { result.append((left, index)) }
            previous[file] = index
        }
        return result
    }

    /// Cheap gate using only hypotheses already computed for the two excerpts.
    /// A confidently heard different word on either side vetoes the repair.
    static func probe(left: String, right: String, leftWords: [RecognitionTimedWord],
                      rightWords: [RecognitionTimedWord], cut: Double, sharedAudio: Range<Double>) -> Probe? {
        let a = Text(left), b = Text(right)
        guard a.tokens.count >= 2, b.tokens.count >= 2, leftWords.count >= 2, rightWords.count >= 2,
              cut.isFinite, sharedAudio.lowerBound.isFinite, sharedAudio.upperBound.isFinite,
              sharedAudio.lowerBound < cut, sharedAudio.upperBound > cut,
              let leftToken = a.tokens.last, let rightToken = b.tokens.first,
              a.safeBoundary(leftToken), b.safeBoundary(rightToken),
              right[..<rightToken.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let ordinaryEnd = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?…"))
        let leftGap = left[a.tokens[a.tokens.count - 2].range.upperBound..<leftToken.range.lowerBound]
        let leftSuffix = left[leftToken.range.upperBound...]
        let rightGap = right[rightToken.range.upperBound..<b.tokens[1].range.lowerBound]
        guard leftGap.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains),
              leftSuffix.unicodeScalars.allSatisfy(ordinaryEnd.contains),
              rightGap.unicodeScalars.allSatisfy(ordinaryEnd.contains) else { return nil }
        let before = a.tokens[a.tokens.count - 2].canonical, after = b.tokens[1].canonical
        guard before.count >= 3, after.count >= 3, before.allSatisfy(\.isLetter), after.allSatisfy(\.isLetter) else { return nil }
        let leftObserved: RecognitionTimedWord?
        if normalize(leftWords.last!.text) == before { leftObserved = nil }
        else if normalize(leftWords[leftWords.count - 2].text) == before { leftObserved = leftWords.last }
        else { return nil }
        let rightObserved: RecognitionTimedWord?
        if normalize(rightWords[0].text) == after { rightObserved = nil }
        else if normalize(rightWords[1].text) == after { rightObserved = rightWords[0] }
        else { return nil }
        let observed = [leftObserved, rightObserved].compactMap { $0 }
        let complete = Set(observed.map { normalize($0.text) }.filter { $0.count >= 4 })
        guard complete.count == 1, let word = complete.first,
              word.allSatisfy(\.isLetter), word != before, word != after else { return nil }
        // A cut can leave only one or two acoustic letters on one side. This
        // exact prefix never supplies the replacement; both full-context
        // decodes must later agree on the complete word and its actual timing.
        guard observed.allSatisfy({ piece in
            let text = normalize(piece.text)
            let cyrillic = text.unicodeScalars.allSatisfy { (0x0430...0x044F).contains($0.value) || $0.value == 0x0451 }
            let agrees = text == word || ((1...2).contains(text.count) && cyrillic && !completeShortWords.contains(text) && word.hasPrefix(text))
            return agrees && piece.start.isFinite && piece.end.isFinite && piece.end > piece.start
        }) else { return nil }
        return Probe(left: left, right: right, leftAnchor: before, rightAnchor: after,
                     word: word, observed: observed, cut: cut, sharedAudio: sharedAudio)
    }

    /// Full audio must contain one unique anchored word in the shared region.
    static func proposal(_ probe: Probe, unionWords: [RecognitionTimedWord]) -> Proposal? {
        let tokens = unionWords.map { normalize($0.text) }
        let matches = triplets(tokens, probe: probe)
        guard matches.count == 1, let index = matches.first else { return nil }
        let word = unionWords[index]
        guard overlaps(word, probe.sharedAudio),
              unionWords.filter({ normalize($0.text) == probe.word && overlaps($0, probe.sharedAudio) }).count == 1,
              probe.observed.allSatisfy({ overlaps($0, word.start..<word.end) }) else { return nil }
        return Proposal(probe: probe, word: word)
    }

    /// The unprompted Qwen replay must independently agree on the exact unique
    /// anchor/word/anchor sequence. Preserve every word outside the two fragments.
    static func confirm(_ proposal: Proposal, reread: String,
                        normalizeReplacement: (String) -> String = { $0 }) -> Revision? {
        let probe = proposal.probe, replay = Text(reread)
        let matches = triplets(replay.tokens.map(\.canonical), probe: probe)
        guard matches.count == 1, let index = matches.first, replay.safeBoundary(replay.tokens[index]) else { return nil }
        // Spelling preferences apply only after the raw audio proof succeeds,
        // and only to this token; unrelated transcript text stays untouched.
        let replacement = normalizeReplacement(replay.tokens[index].raw)
        guard replacement.contains(where: \.isLetter) else { return nil }
        let left = Text(probe.left), right = Text(probe.right)
        guard let last = left.tokens.last, let first = right.tokens.first else { return nil }
        let revisedLeft: String, revisedRight: String
        if proposal.word.start < probe.cut {
            revisedLeft = probe.left.replacingCharacters(in: last.range, with: replacement)
            var suffix = probe.right[first.range.upperBound...]
            let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:.!?…—–-"))
            while let scalar = suffix.unicodeScalars.first, separators.contains(scalar) { suffix = suffix.dropFirst() }
            revisedRight = String(suffix)
        } else {
            let prefix = probe.left[..<last.range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            revisedLeft = prefix + probe.left[last.range.upperBound...]
            revisedRight = probe.right.replacingCharacters(in: first.range, with: replacement)
        }
        guard !revisedLeft.isEmpty, !revisedRight.isEmpty else { return nil }
        return Revision(left: revisedLeft, right: revisedRight)
    }

    private static func triplets(_ words: [String], probe: Probe) -> [Int] {
        guard words.count >= 3 else { return [] }
        return (1..<(words.count - 1)).filter {
            words[$0 - 1] == probe.leftAnchor && words[$0] == probe.word && words[$0 + 1] == probe.rightAnchor
        }
    }
}
