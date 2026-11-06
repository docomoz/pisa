import Foundation
import NaturalLanguage

enum RecognitionConsensus {
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
    private static let meaningMarkers: Set<String> = [
        "не", "ни", "нет", "нельзя", "никогда", "никто", "ничего", "нигде", "никак", "без", "или", "либо",
    ]
    private static let affirmations: Set<String> = ["да", "ага", "угу", "окей"]

    static func revisedText(original: String, candidate: String, corroboration: String,
                            vocabulary: String, allowShortTurn: Bool = false, expandedAudio: Bool = false) -> String? {
        guard [original, candidate, corroboration].allSatisfy(MeetingSpeechText.accepts) else { return nil }
        let source = tokens(original), retry = tokens(candidate), evidence = tokens(corroboration)
        let first = source.map(\.key), checked = retry.map(\.key), heard = evidence.map(\.key)
        guard first != heard, [first, checked, heard].allSatisfy({ $0.filter(isRussian).count * 2 > $0.count }) else { return nil }
        guard !expandedAudio || (first.count == checked.count && first.count == heard.count) else { return nil }

        let protected = protectedWords(in: first, vocabulary: vocabulary)
        // Either output can propose the local edit. Both must agree at the
        // same anchors, even if one differs elsewhere on a glossary spelling.
        for comparison in [heard, checked] where comparison != first {
            let (old, proposal) = differingWords(first, comparison)
            guard old.lowerBound > 0, old.upperBound < first.count, old.count <= 4, proposal.count <= 4,
                  canChange(first, range: old, protected: protected) else { continue }
            let left = first[old.lowerBound - 1], right = first[old.upperBound]
            let independent = anchors(in: heard, left: left, right: right)
            let confirmed = anchors(in: checked, left: left, right: right)
            guard anchors(in: first, left: left, right: right) == [old],
                  independent.count == 1, let new = independent.first,
                  confirmed.count == 1, let position = confirmed.first,
                  heard[new].allSatisfy({ isReplaceable($0) && !affirmations.contains($0) }),
                  checked[position].elementsEqual(heard[new]) else { continue }
            let sourceRange = source[old.lowerBound - 1].range.upperBound..<source[old.upperBound].range.lowerBound
            let evidenceRange = evidence[new.lowerBound - 1].range.upperBound..<evidence[new.upperBound].range.lowerBound
            let candidateRange = retry[position.lowerBound - 1].range.upperBound..<retry[position.upperBound].range.lowerBound
            guard !intersectsLiteral(sourceRange, in: original),
                  !intersectsLiteral(candidateRange, in: candidate),
                  !intersectsLiteral(evidenceRange, in: corroboration) else { continue }
            // Include the word separators, so a split can remove a stale hyphen.
            // Avoid moving a sentence or opening quote across an anchor.
            guard boundaryMarks(original[sourceRange]) == boundaryMarks(corroboration[evidenceRange]) else { continue }
            return String(original[..<sourceRange.lowerBound]) + corroboration[evidenceRange] + original[sourceRange.upperBound...]
        }

        // Without both anchors, only a complete, independently agreed short
        // Russian turn can replace the original. The caller owns audio bounds.
        let (old, new) = differingWords(first, heard)
        guard allowShortTurn, !original.contains(where: { "\"'«»“”‘’`/\\@".contains($0) }),
              first.filter(affirmations.contains) == heard.filter(affirmations.contains),
              (2...6).contains(first.count), (2...6).contains(heard.count),
              first.allSatisfy(isReplaceable), heard.allSatisfy(isReplaceable),
              canChange(first, range: old, protected: protected),
              soundsCompatible(first, heard), agreesWithShortTurn(retry, keys: checked, candidate: candidate, heard: heard) else { return nil }
        // Retain the exact spelling and place of every original glossary
        // occurrence, including words repeated elsewhere in the short turn.
        for range in protected {
            let shift = range.upperBound <= old.lowerBound ? 0 : new.count - old.count
            let originalRange = source[range.lowerBound].range.lowerBound..<source[range.upperBound - 1].range.upperBound
            let heardRange = evidence[range.lowerBound + shift].range.lowerBound..<evidence[range.upperBound - 1 + shift].range.upperBound
            guard original[originalRange] == corroboration[heardRange] else { return nil }
        }
        let punctuation = CharacterSet(charactersIn: ".!?…")
        let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidenceTrimmed = corroboration.trimmingCharacters(in: .whitespacesAndNewlines)
        let ending = originalTrimmed.unicodeScalars.reversed().prefix { punctuation.contains($0) }.reversed()
        let trailingCount = evidenceTrimmed.unicodeScalars.reversed().prefix { punctuation.contains($0) }.count
        let text = String(evidenceTrimmed.unicodeScalars.dropLast(trailingCount))
        return text + String(String.UnicodeScalarView(ending))
    }

    private struct Token {
        var key: String
        var range: Range<String.Index>
    }

    private static func tokens(_ text: String) -> [Token] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return Token(key: text[range].lowercased().replacingOccurrences(of: "ё", with: "е"), range: range)
        }
    }

    private static func isRussian(_ word: String) -> Bool {
        word.unicodeScalars.allSatisfy { (0x0430...0x044f).contains($0.value) }
    }

    private static func isReplaceable(_ word: String) -> Bool {
        isRussian(word) && !meaningMarkers.contains(word)
    }

    private static func differingWords(_ first: [String], _ second: [String]) -> (Range<Int>, Range<Int>) {
        let prefix = zip(first, second).prefix { $0.0 == $0.1 }.count
        let suffix = zip(first.dropFirst(prefix).reversed(), second.dropFirst(prefix).reversed())
            .prefix { $0.0 == $0.1 }.count
        return (prefix..<(first.count - suffix), prefix..<(second.count - suffix))
    }

    private static func canChange(_ words: [String], range: Range<Int>, protected: [Range<Int>]) -> Bool {
        words[range].allSatisfy { isReplaceable($0) && !affirmations.contains($0) } && !protected.contains { term in
            term.overlaps(range) || (range.isEmpty && term.lowerBound < range.lowerBound && term.upperBound > range.lowerBound)
        }
    }

    private static func protectedWords(in words: [String], vocabulary: String) -> [Range<Int>] {
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(RussianRecognition.words).filter { !$0.isEmpty }
        return terms.flatMap { term in
            words.indices.compactMap { start in
                words[start...].starts(with: term) ? start..<(start + term.count) : nil
            }
        }
    }

    private static func anchors(in words: [String], left: String, right: String) -> [Range<Int>] {
        words.indices.filter { words[$0] == left }.flatMap { index in
            let start = index + 1
            return words.indices.dropFirst(start).prefix(5).compactMap { end in
                words[end] == right ? start..<end : nil
            }
        }
    }

    private static func intersectsLiteral(_ range: Range<String.Index>, in text: String) -> Bool {
        let span = NSRange(range, in: text)
        return TranscriptOrthography.literalRanges(in: text).contains { NSIntersectionRange($0, span).length > 0 }
    }

    private static func boundaryMarks(_ text: Substring) -> String {
        String(text.filter { ".!?…\n\r«»“”\"()[]".contains($0) })
    }

    private static func soundsCompatible(_ first: [String], _ second: [String]) -> Bool {
        let old = first.joined(), new = second.joined()
        return old.difference(from: new).count * 2 <= max(old.count, new.count)
    }

    private static func agreesWithShortTurn(_ retry: [Token], keys: [String], candidate: String, heard: [String]) -> Bool {
        if keys == heard { return true }
        // One additional coordinating conjunction between the same past verbs
        // does not change the words both recognizers heard. Never copy it.
        guard keys.count == heard.count + 1 else { return false }
        let index = zip(keys, heard).prefix { $0.0 == $0.1 }.count
        guard index > 0, index + 1 < keys.count, keys[index] == "и",
              keys[(index + 1)...].elementsEqual(heard[index...]) else { return false }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = candidate
        tagger.setLanguage(.russian, range: candidate.startIndex..<candidate.endIndex)
        return [retry[index - 1], retry[index + 1]].allSatisfy { token in
            guard ["л", "ла", "ло", "ли", "лся", "лась", "лось", "лись"].contains(where: token.key.hasSuffix),
                  let lemma = tagger.tag(at: token.range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue else { return false }
            return ["ть", "ти", "чь", "ться", "тись", "чься"].contains(where: lemma.hasSuffix)
        }
    }
}
