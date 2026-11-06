import Foundation

/// Verify a second acoustic hypothesis with a fresh audio decode. Local repairs
/// keep surrounding words and distinguish acoustic evidence from glossary hints.
enum RussianRecognition {
    private struct NumericRepair {
        var index: Int
        var form: String
        var left: [String]
        var right: [String]
    }

    static func numericRepairContext(in original: String, vocabulary: String,
                                     expected: (String) -> String?) -> String? {
        let repairs = numericRepairs(in: original, vocabulary: vocabulary, expected: expected)
        return repairs.count == 1 ? repairs.first?.form : nil
    }

    static func restoringNumericName(original: String, candidate: String, vocabulary: String,
                                     expected: (String) -> String?) -> String? {
        let repairs = numericRepairs(in: original, vocabulary: vocabulary, expected: expected)
        guard repairs.count == 1, let repair = repairs.first else { return nil }
        let source = tokens(in: original), retry = tokens(in: candidate)
        guard retry.count >= 6 else { return nil }
        let literals = TranscriptOrthography.literalRanges(in: candidate)
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { words($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.isEmpty }
        let positions = (2..<(retry.count - 2)).flatMap { position in
            (1...2).compactMap { width -> Range<Int>? in
                guard position + width + 1 < retry.count,
                      retry[(position - 2)..<position].map(\.key) == repair.left,
                      retry[(position + width)...(position + width + 1)].map(\.key) == repair.right else { return nil }
                return position..<(position + width)
            }
        }
        guard positions.count == 1, let span = positions.first, span.count == 2 else { return nil }
        let formRange = retry[span.lowerBound].range.lowerBound..<retry[span.upperBound - 1].range.upperBound
        let context = retry[span.lowerBound - 2].range.lowerBound..<retry[span.upperBound + 1].range.upperBound
        guard candidate[formRange] == repair.form,
              !literals.contains(where: { NSIntersectionRange($0, NSRange(context, in: candidate)).length > 0 }),
              !candidate[context].contains(where: { ".!?…\n\r".contains($0) }),
              !terms.contains(where: { phrase in
                  guard phrase.count > 2, phrase.count <= retry.count else { return false }
                  return (0...(retry.count - phrase.count)).contains { start in
                      start < span.upperBound && start + phrase.count > span.lowerBound
                          && retry[start..<(start + phrase.count)].map(\.key) == phrase
                  }
              }) else { return nil }
        var result = original
        result.replaceSubrange(source[repair.index].range, with: repair.form)
        return result
    }

    private static func numericRepairs(in text: String, vocabulary: String,
                                       expected: (String) -> String?) -> [NumericRepair] {
        let source = tokens(in: text), literals = TranscriptOrthography.literalRanges(in: text)
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { words($0.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.isEmpty }
        guard source.count >= 5 else { return [] }
        return (2..<(source.count - 2)).compactMap { index in
            let token = source[index]
            guard let form = expected(token.text) else { return nil }
            let context = source[index - 2].range.lowerBound..<source[index + 2].range.upperBound
            guard !literals.contains(where: { NSIntersectionRange($0, NSRange(context, in: text)).length > 0 }),
                  !text[context].contains(where: { ".!?…\n\r".contains($0) }),
                  !terms.contains(where: { phrase in
                      guard phrase.count <= source.count else { return false }
                      return (0...(source.count - phrase.count)).contains { start in
                          start <= index && index < start + phrase.count
                              && source[start..<(start + phrase.count)].map(\.key) == phrase
                      }
                  }) else { return nil }
            let left = source[(index - 2)..<index].map(\.key), right = source[(index + 1)...(index + 2)].map(\.key)
            let positions = (2..<(source.count - 2)).filter { i in
                source[(i - 2)..<i].map(\.key) == left && source[(i + 1)...(i + 2)].map(\.key) == right
            }
            guard positions.count == 1 else { return nil }
            return NumericRepair(index: index, form: form, left: left, right: right)
        }
    }

    /// An extra prompted decode supplies acoustic evidence for the ending; no
    /// grammatical inference or whole-sentence replacement is performed here.
    static func restoringNumericEndings(original: String, candidate: String, vocabulary: String) -> String? {
        let allTerms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let source = tokens(in: original), retry = tokens(in: candidate)
        let occurrences = numericBaseOccurrences(in: original, vocabulary: vocabulary)
        let retryLiterals = TranscriptOrthography.literalRanges(in: candidate)
        let suffixes: Set<String> = ["а", "у", "е", "ом", "ем", "ами"]
        var edits: [(Range<String.Index>, String)] = []
        for (index, term) in occurrences {
            let left = source[(index - 2)..<index].map(\.key)
            let right = source[(index + 1)...(index + 2)].map(\.key)
            guard retry.count >= 6 else { continue }
            let matches = (2..<(retry.count - 3)).filter { position in
                guard retry[position].text == term, suffixes.contains(retry[position + 1].key),
                      candidate[retry[position].range.upperBound..<retry[position + 1].range.lowerBound] == "'" else { return false }
                return retry[(position - 2)..<position].map(\.key) == left && retry[(position + 2)...(position + 3)].map(\.key) == right
            }
            guard matches.count == 1, let position = matches.first else { continue }
            let range = retry[position].range.lowerBound..<retry[position + 1].range.upperBound
            let replacement = String(candidate[range])
            guard !retryLiterals.contains(where: { NSIntersectionRange($0, NSRange(range, in: candidate)).length > 0 }),
                  !allTerms.contains(where: { $0 != term && RecognitionVocabulary.contains($0, in: replacement) }) else { continue }
            edits.append((source[index].range, replacement))
        }
        guard edits.count == 1, let edit = edits.first else { return nil }
        var result = original
        result.replaceSubrange(edit.0, with: edit.1)
        return result
    }

    static func needsNumericEndingCheck(in text: String, vocabulary: String) -> Bool {
        !numericBaseOccurrences(in: text, vocabulary: vocabulary).isEmpty
    }

    private static func numericBaseOccurrences(in text: String, vocabulary: String) -> [(Int, String)] {
        let allTerms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let terms = Set(allTerms.filter { RecognitionVocabulary.numericForms(for: $0) != nil })
        let source = tokens(in: text), literals = TranscriptOrthography.literalRanges(in: text)
        guard source.count >= 5, !terms.isEmpty else { return [] }
        return (2..<(source.count - 2)).compactMap { index in
            let token = source[index]
            guard terms.contains(token.text),
                  !literals.contains(where: { NSIntersectionRange($0, NSRange(token.range, in: text)).length > 0 }) else { return nil }
            let protected = allTerms.filter { $0 != token.text }.contains { term in
                let phrase = words(term)
                guard !phrase.isEmpty, phrase.count <= source.count else { return false }
                return (0...(source.count - phrase.count)).contains { start in
                    start <= index && index < start + phrase.count && source[start..<(start + phrase.count)].map(\.key) == phrase
                }
            }
            guard !protected else { return nil }
            let separator = text[token.range.upperBound..<source[index + 1].range.lowerBound]
            guard !separator.hasPrefix("'"), !separator.hasPrefix("’") else { return nil }
            let left = source[(index - 2)..<index].map(\.key), right = source[(index + 1)...(index + 2)].map(\.key)
            let matches = (2..<(source.count - 2)).filter { position in
                source[position].text == token.text && source[(position - 2)..<position].map(\.key) == left
                    && source[(position + 1)...(position + 2)].map(\.key) == right
            }
            return matches.count == 1 ? (index, token.text) : nil
        }
    }
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
                            vocabulary: String, usesCyrillicHints: Bool, dictionaryCorroboration: String? = nil) -> String? {
        guard MeetingSpeechText.accepts(candidate) else { return nil }
        let acoustic = localizedRepair(original: original, candidate: candidate,
                                       corroboration: corroboration, vocabulary: vocabulary) ?? original
        if let revised = generalDictionaryRepair(original: acoustic, candidate: candidate,
                                                  hypothesis: dictionaryCorroboration ?? SpokenVocabulary(vocabulary).apply(to: corroboration), vocabulary: vocabulary) {
            return revised
        }
        if let revised = phoneticDictionaryRepair(original: acoustic, candidate: candidate,
                                                   hypothesis: hypothesis, vocabulary: vocabulary) { return revised }
        if usesCyrillicHints {
            let revised = localizedDictionaryRepair(original: acoustic, candidate: candidate,
                                                     hypothesis: hypothesis, vocabulary: vocabulary) ?? acoustic
            return revised == original ? nil : revised
        }
        if acoustic != original { return acoustic }
        guard accepts(candidate: candidate, original: original, vocabulary: vocabulary),
              preservesCorroboratedPhrases(candidate: candidate, original: original, corroboration: corroboration) else { return nil }
        return RecognitionConsensus.revisedText(original: original, candidate: candidate,
            corroboration: corroboration, vocabulary: vocabulary)
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

    static func generalDictionaryRepair(original: String, candidate: String, hypothesis: String, vocabulary: String) -> String? {
        let allTerms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let terms = allTerms.filter { term in
            if words(term).count == 1 { return true }
            let parts = term.split(separator: "-", omittingEmptySubsequences: false)
            return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isLetter) }
        }
        guard !terms.isEmpty else { return nil }
        let source = tokens(in: original), retry = tokens(in: candidate), evidence = tokens(in: hypothesis)
        guard source.filter({ isCyrillic($0.key) }).count * 2 > source.count else { return nil }
        let normalizer = SpokenVocabulary(vocabulary)
        let protected: Set<String> = ["не", "ни", "нет", "нельзя", "никогда", "никто", "ничего", "нигде", "никак", "без", "или", "либо", "да", "ага", "угу"]
        let originalLiterals = TranscriptOrthography.literalRanges(in: original)
        let candidateLiterals = TranscriptOrthography.literalRanges(in: candidate)
        let evidenceLiterals = TranscriptOrthography.literalRanges(in: hypothesis)
        func matchesTerm(_ term: String, _ spelling: String) -> Bool {
            if words(term).count == 2 { return spelling == term }
            if RecognitionVocabulary.contains(term, in: spelling) { return true }
            // Regular case forms of a title-case surname ending in -ов/-ев/-ин.
            let folded = term.lowercased().replacingOccurrences(of: "ё", with: "е")
            let value = spelling.lowercased().replacingOccurrences(of: "ё", with: "е")
            guard term.first?.isUppercase == true, term.dropFirst().allSatisfy(\.isLowercase),
                  ["ов", "ев", "ин", "ын"].contains(where: folded.hasSuffix), value.hasPrefix(folded) else { return false }
            return ["ым", "ыми", "ых"].contains(String(value.dropFirst(folded.count)))
        }
        func editDistance(_ left: String, _ right: String) -> Int {
            let a = Array(left), b = Array(right)
            var row = Array(0...b.count)
            for (i, x) in a.enumerated() {
                var next = [i + 1]
                for (j, y) in b.enumerated() {
                    next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1)))
                }
                row = next
            }
            return row[b.count]
        }

        // Return ranges strictly between uniquely identifiable surrounding words.
        func matches(_ tokens: [Token], left: String, right: String, maximum: Int) -> [Range<Int>] {
            guard tokens.count >= 3 else { return [] }
            var spans: [Range<Int>] = []
            for leftIndex in 0..<(tokens.count - 2) where tokens[leftIndex].key == left {
                for rightIndex in (leftIndex + 2)..<min(tokens.count, leftIndex + maximum + 2) where tokens[rightIndex].key == right {
                    spans.append((leftIndex + 1)..<rightIndex)
                }
            }
            return spans
        }
        func inProtectedPhrase(_ index: Int) -> Bool {
            allTerms.contains { term in
                let phrase = words(term)
                guard !phrase.isEmpty, phrase.count <= source.count else { return false }
                return (0...(source.count - phrase.count)).contains { start in
                    guard start <= index, index < start + phrase.count else { return false }
                    return source[start..<(start + phrase.count)].map(\.key) == phrase
                }
            }
        }
        func safeContext(_ text: String, _ tokens: [Token], _ span: Range<Int>, _ literals: [NSRange]) -> Bool {
            let range = tokens[span.lowerBound - 1].range.lowerBound..<tokens[span.upperBound].range.upperBound
            let nsRange = NSRange(range, in: text)
            let local = text[range]
            return !literals.contains { NSIntersectionRange($0, nsRange).length > 0 }
                && !local.contains(where: { "/\\@`«»“”\"".contains($0) })
        }
        func boundaries(_ text: String, _ tokens: [Token], _ span: Range<Int>) -> String {
            String(text[tokens[span.lowerBound - 1].range.upperBound..<tokens[span.upperBound].range.lowerBound].filter { ".!?…\n\r".contains($0) })
        }
        var edits: [(Range<String.Index>, String)] = []
        guard retry.count >= 3 else { return nil }
        // Independently confirmed inflection may adjust a known acronym without
        // authorizing a change to the acronym itself or to another glossary term.
        let suffixes: Set<String> = ["а", "у", "е", "ы", "и", "ом", "ем", "ам", "ах", "ами", "ов", "ка", "ки", "ку", "ке", "кой", "кам", "ках", "ками"]
        for term in terms where term.contains(where: \.isNumber) || term == term.uppercased() {
            func validForm(_ text: String) -> Bool {
                if text == term { return true }
                guard text.hasPrefix(term + "'") else { return false }
                return suffixes.contains(String(text.dropFirst(term.count + 1)))
            }
            for index in 1..<(retry.count - 1) {
                for width in 1...2 where index + width < retry.count {
                    let span = index..<(index + width)
                    let replacementRange = retry[index].range.lowerBound..<retry[span.upperBound - 1].range.upperBound
                    let replacement = String(candidate[replacementRange])
                    guard validForm(replacement) else { continue }
                    let left = retry[index - 1].key, right = retry[span.upperBound].key
                    let sourceMatches = matches(source, left: left, right: right, maximum: 2)
                    let evidenceMatches = matches(evidence, left: left, right: right, maximum: 2)
                    guard matches(retry, left: left, right: right, maximum: 2) == [span],
                          sourceMatches.count == 1, let old = sourceMatches.first,
                          evidenceMatches.count == 1, let heard = evidenceMatches.first else { continue }
                    let oldRange = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
                    let heardRange = evidence[heard.lowerBound].range.lowerBound..<evidence[heard.upperBound - 1].range.upperBound
                    let originalForm = String(original[oldRange])
                    guard originalForm != replacement, validForm(originalForm), hypothesis[heardRange] == replacement,
                          !allTerms.contains(where: { other in
                              other != term && (RecognitionVocabulary.contains(other, in: originalForm)
                                  || RecognitionVocabulary.contains(other, in: replacement))
                          }),
                          safeContext(original, source, old, originalLiterals),
                          safeContext(candidate, retry, span, candidateLiterals),
                          safeContext(hypothesis, evidence, heard, evidenceLiterals),
                          boundaries(original, source, old) == boundaries(candidate, retry, span),
                          boundaries(original, source, old) == boundaries(hypothesis, evidence, heard) else { continue }
                    edits.append((oldRange, replacement))
                }
            }
        }
        // A repeated canonical term can repair a repeated misrecognition. The
        // entire phrase, including its punctuation, needs independent agreement.
        for start in 1..<(retry.count - 1) {
            for count in 2...3 {
                for withPreposition in [false, true] {
                    let termStart = start + (withPreposition ? 1 : 0)
                    let end = termStart + count
                    guard end < retry.count else { continue }
                    if withPreposition && !["по", "с", "к", "в", "у"].contains(retry[start].key) { continue }
                    let canonical = retry[termStart].text
                    guard (termStart..<end).allSatisfy({ retry[$0].text == canonical }),
                          terms.filter({ RecognitionVocabulary.contains($0, in: canonical) }).count == 1,
                          normalizer.apply(to: canonical) == canonical else { continue }
                    let phrase = start..<end
                    let left = retry[start - 1].key, right = retry[end].key
                    let sourceMatches = matches(source, left: left, right: right, maximum: 3)
                    let evidenceMatches = matches(evidence, left: left, right: right, maximum: 4)
                    guard matches(retry, left: left, right: right, maximum: 4) == [phrase],
                          sourceMatches.count == 1, let old = sourceMatches.first, old.count == count,
                          evidenceMatches.count == 1, let heard = evidenceMatches.first else { continue }
                    let replacementRange = retry[start].range.lowerBound..<retry[end - 1].range.upperBound
                    let heardRange = evidence[heard.lowerBound].range.lowerBound..<evidence[heard.upperBound - 1].range.upperBound
                    let replacement = String(candidate[replacementRange])
                    let separatorCharacters = CharacterSet(charactersIn: " .,!?…\t\n\r")
                    guard hypothesis[heardRange] == replacement,
                          (start..<(end - 1)).allSatisfy({ index in
                              candidate[retry[index].range.upperBound..<retry[index + 1].range.lowerBound]
                                  .unicodeScalars.allSatisfy(separatorCharacters.contains)
                          }),
                          old.allSatisfy({ i in
                              let token = source[i]
                              return token.key == source[old.lowerBound].key && isCyrillic(token.key)
                                  && !protected.contains(token.key)
                                  && !(token.text.first?.isUppercase == true && token.text.dropFirst().allSatisfy(\.isLowercase))
                                  && !inProtectedPhrase(i)
                                  && !terms.contains(where: { RecognitionVocabulary.contains($0, in: token.text) })
                          }),
                          safeContext(original, source, old, originalLiterals),
                          safeContext(candidate, retry, phrase, candidateLiterals),
                          safeContext(hypothesis, evidence, heard, evidenceLiterals) else { continue }
                    let oldRange = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
                    edits.append((oldRange, replacement))
                }
            }
        }
        for index in 1..<(retry.count - 1) {
            for width in 1...2 where index + width < retry.count {
                let span = index..<(index + width)
                var preposition: String?
                if width == 2 {
                    let separator = candidate[retry[index].range.upperBound..<retry[index + 1].range.lowerBound]
                    if separator.allSatisfy(\.isWhitespace), !separator.isEmpty,
                       ["по", "с", "к", "в", "у"].contains(retry[index].key) {
                        preposition = retry[index].key
                    } else if separator != "'" && separator != "’" && separator != "-" { continue }
                }
                let replacementRange = retry[index].range.lowerBound..<retry[span.upperBound - 1].range.upperBound
                let replacement = String(candidate[replacementRange])
                let termText = preposition == nil ? replacement : retry[index + 1].text
                let matchingTerms = terms.filter { matchesTerm($0, termText) }
                guard matchingTerms.count == 1, normalizer.apply(to: replacement) == replacement else { continue }
                if width == 2, candidate[retry[index].range.upperBound..<retry[index + 1].range.lowerBound] == "-",
                   words(matchingTerms[0]).count != 2 { continue }
                let left = retry[index - 1].key, right = retry[span.upperBound].key
                let evidenceMatches = matches(evidence, left: left, right: right, maximum: 3)
                let sourceMatches = matches(source, left: left, right: right, maximum: 3)
                guard matches(retry, left: left, right: right, maximum: 3) == [span],
                      evidenceMatches.count == 1, let heard = evidenceMatches.first,
                      sourceMatches.count == 1, let old = sourceMatches.first else { continue }
                let heardRange = evidence[heard.lowerBound].range.lowerBound..<evidence[heard.upperBound - 1].range.upperBound
                guard hypothesis[heardRange] == replacement else { continue }
                let oldRange = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
                guard original[oldRange] != replacement,
                      preposition.map({ prefix in
                          guard old.count == 1 else { return false }
                          let normalized = source[old.lowerBound].key.replacingOccurrences(of: "а", with: "о")
                          return normalized.hasPrefix(prefix)
                      }) ?? true,
                      old.allSatisfy({ i in
                          let token = source[i]
                          let isName = token.text.first?.isUppercase == true && token.text.dropFirst().allSatisfy(\.isLowercase)
                          let nearbyName = old.count == 1 && token.text.count >= 5 && isCyrillic(words(termText).joined())
                              && editDistance(token.key, words(termText).joined()) <= 2
                          return isCyrillic(token.key) && !protected.contains(token.key)
                              && (!isName || nearbyName)
                              && !inProtectedPhrase(i)
                              && !terms.contains(where: { matchesTerm($0, token.text) })
                      }),
                      safeContext(original, source, old, originalLiterals),
                      safeContext(candidate, retry, span, candidateLiterals),
                      safeContext(hypothesis, evidence, heard, evidenceLiterals),
                      boundaries(original, source, old) == boundaries(candidate, retry, span),
                      boundaries(original, source, old) == boundaries(hypothesis, evidence, heard) else { continue }
                edits.append((oldRange, replacement))
            }
        }
        guard edits.count == 1, let edit = edits.first else { return nil }
        var revised = original
        revised.replaceSubrange(edit.0, with: edit.1)
        return revised
    }

    private static func phoneticDictionaryRepair(original: String, candidate: String, hypothesis: String, vocabulary: String) -> String? {
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let eligible = terms.filter { term in
            term.count >= 5 && term.unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
        }
        guard !eligible.isEmpty else { return nil }
        let normalizer = SpokenVocabulary(vocabulary)
        let source = tokens(in: original), retry = tokens(in: candidate), evidence = tokens(in: hypothesis)
        guard retry.count >= 3, source.filter({ isCyrillic($0.key) }).count * 2 > source.count else { return nil }
        func matches(_ tokens: [Token], _ left: String, _ right: String) -> [Range<Int>] {
            guard tokens.count >= 3 else { return [] }
            var found: [Range<Int>] = []
            for i in 0..<(tokens.count - 2) where tokens[i].key == left {
                for j in (i + 2)..<min(tokens.count, i + 5) where tokens[j].key == right { found.append((i + 1)..<j) }
            }
            return found
        }
        func safe(_ text: String, _ tokens: [Token], _ span: Range<Int>) -> Bool {
            let range = tokens[span.lowerBound - 1].range.lowerBound..<tokens[span.upperBound].range.upperBound
            let local = text[range]
            return !local.contains(where: { "/\\@`«»“”\"".contains($0) }) &&
                !TranscriptOrthography.literalRanges(in: text).contains { NSIntersectionRange($0, NSRange(range, in: text)).length > 0 }
        }
        var edits: [(Range<String.Index>, String)] = []
        for index in 1..<(retry.count - 1) {
            let term = retry[index].text
            guard eligible.filter({ $0 == term }).count == 1 else { continue }
            for preposition in [false, true] {
                let start = index - (preposition ? 1 : 0)
                guard start > 0 else { continue }
                if preposition && !["в", "к", "с", "у"].contains(retry[start].key) { continue }
              for conjunction in [false, true] {
                let end = index + 1 + (conjunction ? 1 : 0)
                guard end < retry.count else { continue }
                if conjunction {
                    guard retry[index + 1].key == "и",
                          candidate[retry[index].range.upperBound..<retry[index + 1].range.lowerBound].allSatisfy(\.isWhitespace) else { continue }
                }
                let span = start..<end, left = retry[start - 1].key, right = retry[end].key
                let sourceMatches = matches(source, left, right), evidenceMatches = matches(evidence, left, right)
                guard matches(retry, left, right) == [span], sourceMatches.count == 1, let old = sourceMatches.first,
                      evidenceMatches.count == 1, let heard = evidenceMatches.first else { continue }
                let retryRange = retry[start].range.lowerBound..<retry[end - 1].range.upperBound
                let heardRange = evidence[heard.lowerBound].range.lowerBound..<evidence[heard.upperBound - 1].range.upperBound
                let oldRange = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
                let oldText = String(original[oldRange])
                guard candidate[retryRange] == hypothesis[heardRange], normalizer.promptHypothesis(oldText) == term,
                      !preposition || oldText.lowercased().hasPrefix(retry[start].key),
                      old.allSatisfy({ isCyrillic(source[$0].key) }),
                      oldText.allSatisfy({ $0.isLetter || $0.isWhitespace || "-‐‑".contains($0) }),
                      !terms.contains(where: { $0 != term && RecognitionVocabulary.contains($0, in: oldText) }),
                      safe(original, source, old), safe(candidate, retry, span), safe(hypothesis, evidence, heard) else { continue }
                edits.append((oldRange, preposition ? retry[start].text + " " + term : term))
              }
            }
        }
        guard edits.count == 1, let edit = edits.first else { return nil }
        var result = original
        result.replaceSubrange(edit.0, with: edit.1)
        return result
    }

    private static func applyRepairs(original: String, proposals: [RepairProposal], matching: [RepairProposal], vocabulary: String) -> String? {
        let source = tokens(in: original)
        let sourceWords = source.map(\.key)
        let literals = TranscriptOrthography.literalRanges(in: original)
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
                    && proposal.matches(source[index], preceding: previous?.key, separator: separator, vocabulary: vocabulary)
            }
            guard matches.count == 1, let index = matches.first,
                  !literals.contains(where: { NSIntersectionRange($0, NSRange(source[index].range, in: original)).length > 0 }),
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

        func matches(_ token: Token, preceding: String?, separator: Substring, vocabulary: String) -> Bool {
            let parts = RussianRecognition.words(replacement)
            if parts.count == 2 {
                guard preceding != parts[0], RussianRecognition.isCyrillic(token.key) else { return false }
                if token.key == parts[1] {
                    // Insert a missing preposition only at a comma boundary.
                    // A bare name may already be governed by an earlier word.
                    return separator.trimmingCharacters(in: .whitespacesAndNewlines) == ","
                }
                guard token.key.hasPrefix(parts[0]) else { return false }
                if RussianRecognition.withinOneEdit(token.key, parts.joined()) { return true }
                // A fused preposition and name can lose one spelling letter and
                // one inflection letter. Only an unambiguous explicit name may
                // authorize this wider edit; candidate and verifier still have
                // to agree on the same anchored phrase in applyRepairs.
                guard token.key.count >= 5, RussianRecognition.distance(token.key, parts.joined()) <= 2 else { return false }
                let names = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { name in
                        name.count >= 4 && name.hasSuffix("а") && name.first?.isUppercase == true
                            && name.dropFirst().allSatisfy(\.isLowercase) && RussianRecognition.isCyrillic(RussianRecognition.words(name).joined())
                    }
                let matching = names.filter { name in
                    let instrumental = RussianRecognition.words(String(name.dropLast()) + "ой").joined()
                    return RussianRecognition.distance(token.key, parts[0] + instrumental) <= 2
                }
                return matching.count == 1 && RecognitionVocabulary.contains(matching[0], in: parts[1])
            }
            guard RussianRecognition.isLatinAcronym(token.text),
                  let transliteration = replacement.applyingTransform(.toLatin, reverse: false)?
                    .applyingTransform(.stripDiacritics, reverse: false)?.lowercased() else { return false }
            if token.key.count != transliteration.count {
                // The glossary may suggest one omitted repeated letter, but
                // only a fresh decode at the same anchored location can accept it.
                return transliteration.count == token.key.count + 1
                    && SpokenVocabulary(vocabulary).promptHypothesis(token.text) == replacement
            }
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
        let literals = TranscriptOrthography.literalRanges(in: text)
        return tokens.indices.compactMap { index in
            guard index + 2 < tokens.count else { return nil }
            let token = tokens[index]
            guard !literals.contains(where: { NSIntersectionRange($0, NSRange(token.range, in: text)).length > 0 }) else { return nil }
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

    private static func distance(_ first: String, _ second: String) -> Int {
        let left = Array(first), right = Array(second)
        var row = Array(0...right.count)
        for (i, character) in left.enumerated() {
            var next = [i + 1]
            for (j, other) in right.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1)))
            }
            row = next
        }
        return row[right.count]
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
