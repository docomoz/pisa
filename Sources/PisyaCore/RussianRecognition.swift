import Foundation

/// Verify a second acoustic hypothesis with a fresh audio decode. Local repairs
/// keep surrounding words and distinguish acoustic evidence from glossary hints.
enum RussianRecognition {
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func shouldRecheck(language: String?, duration: Double, original: String, alternative: String) -> Bool {
        guard language?.lowercased() == "russian", duration >= 2,
              MeetingSpeechText.accepts(alternative) else { return false }
        let first = words(original), second = words(alternative)
        return !first.isEmpty && first != second && similarLength(first, second)
    }

    static func context(vocabulary: String, hypothesis: String) -> String {
        [vocabulary, hypothesis].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func accepts(candidate: String, original: String, vocabulary: String) -> Bool {
        guard MeetingSpeechText.accepts(candidate) else { return false }
        let first = words(original), revised = words(candidate)
        guard similarLength(first, revised) else { return false }
        return preservesVocabulary(candidate: candidate, original: original, vocabulary: vocabulary)
    }

    static func revisedText(original: String, candidate: String, corroboration: String, hypothesis: String,
                            vocabulary: String, usesCyrillicHints: Bool) -> String? {
        guard MeetingSpeechText.accepts(candidate) else { return nil }
        let acoustic = localizedRepair(original: original, candidate: candidate,
                                       corroboration: corroboration, vocabulary: vocabulary) ?? original
        if usesCyrillicHints {
            let revised = localizedDictionaryRepair(original: acoustic, candidate: candidate,
                                                     hypothesis: hypothesis, vocabulary: vocabulary) ?? acoustic
            return revised == original ? nil : revised
        }
        if acoustic != original { return acoustic }
        guard accepts(candidate: candidate, original: original, vocabulary: vocabulary),
              preservesCorroboratedPhrases(candidate: candidate, original: original, corroboration: corroboration) else { return nil }
        return candidate
    }

    private static func preservesCorroboratedPhrases(candidate: String, original: String, corroboration: String) -> Bool {
        let heard = Set(repairProposals(in: corroboration))
        let protected = repairProposals(in: original).filter(heard.contains)
        guard !protected.isEmpty else { return true }
        // A repeated phrase with the same anchors cannot tell us which
        // occurrence the verifier heard, so preserve every original occurrence.
        let counts = Dictionary(grouping: repairProposals(in: candidate), by: { $0 }).mapValues(\.count)
        return Dictionary(grouping: protected, by: { $0 }).allSatisfy { proposal, occurrences in
            counts[proposal, default: 0] >= occurrences.count
        }
    }

    static func localizedRepair(original: String, candidate: String, corroboration: String, vocabulary: String) -> String? {
        applyRepairs(original: original, proposals: repairProposals(in: candidate),
                     matching: repairProposals(in: corroboration), vocabulary: vocabulary)
    }

    /// A vocabulary hint supplies spelling, not independent acoustic evidence.
    /// Only an explicit initialism can use this path after a fresh audio decode.
    static func localizedDictionaryRepair(original: String, candidate: String, hypothesis: String, vocabulary: String) -> String? {
        let terms = Set(vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let proposals = repairProposals(in: candidate).filter { !$0.before.isEmpty && terms.contains($0.replacement) }
        guard !proposals.isEmpty else { return nil }
        return applyRepairs(original: original, proposals: proposals,
                            matching: repairProposals(in: hypothesis), vocabulary: vocabulary)
    }

    private static func applyRepairs(original: String, proposals: [RepairProposal], matching: [RepairProposal], vocabulary: String) -> String? {
        let source = tokens(in: original)
        let sourceWords = source.map(\.key)
        guard sourceWords.filter(isCyrillic).count * 2 > sourceWords.count else { return nil }
        let protected = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(words).filter { !$0.isEmpty }
        var edits: [Int: [String]] = [:]
        for proposal in proposals where matching.filter({ $0 == proposal }).count == 1 {
            let matches = source.indices.filter { index in
                let start = proposal.before.isEmpty ? index : acronymStart(at: index, in: source, text: original)
                let previous = source[..<index].last
                let separator = previous.map { original[$0.range.upperBound..<source[index].range.lowerBound] } ?? ""
                return sourceWords[..<start].suffix(proposal.before.count).elementsEqual(proposal.before)
                    && sourceWords[(index + 1)...].prefix(proposal.after.count).elementsEqual(proposal.after)
                    && proposal.matches(source[index], preceding: previous?.key, separator: separator)
            }
            guard matches.count == 1, let index = matches.first,
                  !protected.contains(where: { phrase in
                      (max(0, index - phrase.count + 1)...index).contains { sourceWords[$0...].starts(with: phrase) }
                  }) else { continue }
            edits[index, default: []].append(proposal.replacement)
        }
        let revised = NSMutableString(string: original)
        for index in edits.keys.sorted(by: >) {
            guard let replacements = edits[index], replacements.count == 1,
                  let replacement = replacements.first else { continue }
            revised.replaceCharacters(in: NSRange(source[index].range, in: original), with: replacement)
        }
        let result = revised as String
        return result == original ? nil : result
    }

    private struct Token {
        var text: String
        var key: String
        var range: Range<String.Index>
    }

    private struct RepairProposal: Hashable {
        var replacement: String
        var before: [String]
        var after: [String]

        func matches(_ token: Token, preceding: String?, separator: Substring) -> Bool {
            let parts = RussianRecognition.words(replacement)
            if parts.count == 2 {
                guard preceding != parts[0], RussianRecognition.isCyrillic(token.key) else { return false }
                if token.key == parts[1] {
                    // Insert a missing preposition only at a comma boundary.
                    // A bare name may already be governed by an earlier word.
                    return separator.trimmingCharacters(in: .whitespacesAndNewlines) == ","
                }
                return token.key.hasPrefix(parts[0]) && RussianRecognition.withinOneEdit(token.key, parts.joined())
            }
            guard RussianRecognition.isLatinAcronym(token.text),
                  let transliteration = replacement.applyingTransform(.toLatin, reverse: false)?
                    .applyingTransform(.stripDiacritics, reverse: false)?.lowercased(),
                  token.key.count == transliteration.count else { return false }
            return RussianRecognition.withinOneEdit(token.key, transliteration)
        }
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    private static func tokens(in text: String) -> [Token] {
        wordPattern.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let word = String(text[range])
            return Token(text: word, key: word.lowercased().replacingOccurrences(of: "ё", with: "е"), range: range)
        }
    }

    private static func repairProposals(in text: String) -> [RepairProposal] {
        let tokens = tokens(in: text)
        let keys = tokens.map(\.key)
        return tokens.indices.compactMap { index in
            guard index + 2 < tokens.count else { return nil }
            let token = tokens[index]
            let after = Array(keys[(index + 1)...(index + 2)])
            if isCyrillic(token.key), (3...6).contains(token.text.count), token.text == token.text.uppercased() {
                let start = acronymStart(at: index, in: tokens, text: text)
                guard start >= 2 else { return nil }
                return RepairProposal(replacement: token.text, before: Array(keys[(start - 2)..<start]), after: after)
            }
            // A glossary word just before a fused name may differ between
            // decoders. Two following words can still anchor that exact name.
            guard index > 0, ["в", "к", "с", "у"].contains(tokens[index - 1].key),
                  token.text.count >= 4, isCyrillic(token.key), token.text.first?.isUppercase == true,
                  token.text.dropFirst().allSatisfy(\.isLowercase),
                  text[tokens[index - 1].range.upperBound..<token.range.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
            return RepairProposal(replacement: tokens[index - 1].key + " " + token.text, before: [], after: after)
        }
    }

    private static func acronymStart(at index: Int, in tokens: [Token], text: String) -> Int {
        // The independent decoder may add an uppercase hyphenated prefix.
        // Match context outside it, without copying it into the source text.
        guard index > 0, isLatinAcronym(tokens[index - 1].text),
              text[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound] == "-" else { return index }
        return index - 1
    }

    private static func isLatinAcronym(_ text: String) -> Bool {
        (2...6).contains(text.count) && text.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    }

    private static func isCyrillic(_ key: String) -> Bool {
        key.unicodeScalars.allSatisfy { (0x0430...0x044F).contains($0.value) }
    }

    private static func withinOneEdit(_ first: String, _ second: String) -> Bool {
        if first.count == second.count { return zip(first, second).filter { $0.0 != $0.1 }.count <= 1 }
        return abs(first.count - second.count) == 1 && first.difference(from: second).count == 1
    }

    static func preservesVocabulary(candidate: String, original: String, vocabulary: String) -> Bool {
        let first = words(original), revised = words(candidate)
        // An acoustic hint must not undo the user's explicit spellings that the
        // first audio decode already recognized. Match phrases, not substrings.
        return vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(words).filter { !$0.isEmpty }.allSatisfy { phrase in
                !contains(first, phrase: phrase) || contains(revised, phrase: phrase)
            }
    }

    private static func similarLength(_ first: [String], _ second: [String]) -> Bool {
        !first.isEmpty && !second.isEmpty &&
            Double(second.count) >= Double(first.count) * 0.75 &&
            Double(second.count) <= Double(first.count) * 1.4
    }

    private static func contains(_ text: [String], phrase: [String]) -> Bool {
        guard text.count >= phrase.count else { return false }
        return (0...(text.count - phrase.count)).contains { Array(text[$0..<($0 + phrase.count)]) == phrase }
    }
}
