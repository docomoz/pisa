import Foundation
import NaturalLanguage

enum RecognitionConsensus {
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+|[\p{Sc}%‰‱]"#)
    private static let meaningMarkers: Set<String> = [
        "не", "ни", "нет", "нельзя", "никогда", "никто", "ничего", "нигде", "никак", "без", "или", "либо",
    ]
    private static let affirmations: Set<String> = ["да", "ага", "угу", "окей"]
    private static let alignmentHesitations: Set<String> = ["э", "ээ", "эм", "мм"]

    /// Retain speech that both unprompted decoders heard on the same long turn.
    /// Keep disagreements visible without losing corroborated speech after them.
    static func corroboratedRussianTurn(original: String, candidate: String, corroboration: String) -> String? {
        guard [original, candidate, corroboration].allSatisfy(MeetingSpeechText.accepts) else { return nil }
        let originalTokens = tokens(original)
        let originalWords = originalTokens.map(\.key)
        let initialisms = Set(originalTokens.compactMap { token -> String? in
            let spelling = original[token.range]
            return (2...6).contains(spelling.count) && spelling.utf8.allSatisfy { (65...90).contains($0) }
                ? token.key : nil
        })
        func alignmentKey(_ token: Token) -> String {
            guard isRussian(token.key), let latin = token.key.applyingTransform(.toLatin, reverse: false),
                  initialisms.contains(latin) else { return token.key }
            return latin
        }
        let candidateTokens = tokens(candidate).filter { !alignmentHesitations.contains($0.key) }
        let acousticTokens = tokens(corroboration).filter { !alignmentHesitations.contains($0.key) }
        let checked = candidateTokens.map(alignmentKey), heard = acousticTokens.map(alignmentKey)
        guard min(checked.count, heard.count) >= max(8, originalWords.count * 2),
              [checked, heard].allSatisfy({ words in
                  words.filter(isRussian).count * 4 >= words.count * 3
                      && !words.indices.contains(where: { words[$0...].starts(with: originalWords) })
              }),
              checked.prefix(3).elementsEqual(heard.prefix(3)), checked.suffix(3).elementsEqual(heard.suffix(3)) else { return nil }

        let difference = checked.difference(from: heard)
        let insertions = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        let removals = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let paired = Array(zip(checked.indices.filter { !insertions.contains($0) },
                               heard.indices.filter { !removals.contains($0) }))
        guard paired.count * 100 >= max(checked.count, heard.count) * 85 else { return nil }

        var gaps: [NSRange] = []
        for (index, pair) in zip(paired, paired.dropFirst()).enumerated() {
            let (left, right) = pair
            let checkedGap = (left.0 + 1)..<right.0, heardGap = (left.1 + 1)..<right.1
            guard !checkedGap.isEmpty || !heardGap.isEmpty else { continue }
            let anchoredBefore = index > 0 && paired[index - 1].0 + 1 == left.0 && paired[index - 1].1 + 1 == left.1
            let anchoredAfter = index + 2 < paired.count && paired[index + 2].0 == right.0 + 1 && paired[index + 2].1 == right.1 + 1
            guard anchoredBefore || anchoredAfter, gaps.count < 3, max(checkedGap.count, heardGap.count) <= 3 else { return nil }
            let disputed = Array(checked[checkedGap]) + Array(heard[heardGap])
            guard disputed.allSatisfy({ word in
                !meaningMarkers.contains(word) && !quantityUnits.contains(word) && !isNumberWord(word)
                    && word.allSatisfy(\.isLetter)
            }) else { return nil }
            let range = candidateTokens[left.0].range.upperBound..<candidateTokens[right.0].range.lowerBound
            guard !intersectsLiteral(range, in: candidate) else { return nil }
            gaps.append(NSRange(range, in: candidate))
        }
        let result = NSMutableString(string: candidate)
        for range in gaps.reversed() {
            result.replaceCharacters(in: range, with: " … ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Only identifies an audio disagreement worth checking; never supplies text.
    static func hasSplitDisagreement(original: String, corroboration: String, vocabulary: String) -> Bool {
        !splitChanges(original: original, corroboration: corroboration, vocabulary: vocabulary).isEmpty
    }

    /// A real acoustic hypothesis may guide the fresh audio decode. Both raw
    /// outputs must agree locally; glossary-normalized output is not evidence.
    static func revisedSplitText(original: String, candidate: String, corroboration: String, vocabulary: String) -> String? {
        guard MeetingSpeechText.accepts(candidate) else { return nil }
        let source = tokens(original), evidence = tokens(corroboration), retry = tokens(candidate)
        let checked = retry.map(\.key)
        var edits: [Range<Int>: Set<String>] = [:]
        for change in splitChanges(original: original, corroboration: corroboration, vocabulary: vocabulary) {
            let matches = splitMatches(in: checked, left: change.left, right: change.right)
            guard matches.count == 1, let matched = matches.first,
                  checked[matched].elementsEqual(evidence[change.new].map(\.key)),
                  retry[matched].map({ candidate[$0.range].lowercased() })
                    == evidence[change.new].map({ corroboration[$0.range].lowercased() }),
                  safeSplitContext(matched, left: change.left, right: change.right, tokens: retry, text: candidate) else { continue }
            let trimmed = trimmedSplit(old: change.old, new: matched, source: source.map(\.key), evidence: checked)
            let replacement = String(candidate[wordRange(trimmed.new, tokens: retry)])
            let originalLetters = source[trimmed.old].map { original[$0.range].lowercased() }.joined()
            let replacementLetters = retry[trimmed.new].map { candidate[$0.range].lowercased() }.joined()
            guard !replacementLetters.difference(from: originalLetters).contains(where: { edit in
                if case .remove(_, let letter, _) = edit { return letter == "ё" }
                return false
            }) else { continue }
            edits[trimmed.old, default: []].insert(replacement)
        }
        // Overlapping or conflicting proposals do not identify a unique edit.
        let accepted = edits.filter { span, replacements in
            replacements.count == 1 && !edits.keys.contains { $0 != span && $0.overlaps(span) }
        }.sorted { $0.key.lowerBound > $1.key.lowerBound }
        guard !accepted.isEmpty else { return nil }
        var revised = original
        for (span, replacements) in accepted {
            revised.replaceSubrange(wordRange(span, tokens: source), with: replacements.first!)
        }
        return revised
    }

    private struct SplitChange {
        var old: Range<Int>
        var new: Range<Int>
        var left: [String]
        var right: [String]
    }

    private static func splitChanges(original: String, corroboration: String, vocabulary: String) -> [SplitChange] {
        guard MeetingSpeechText.accepts(original), MeetingSpeechText.accepts(corroboration) else { return [] }
        let source = tokens(original), evidence = tokens(corroboration)
        let first = source.map(\.key), heard = evidence.map(\.key)
        guard first != heard, [first, heard].allSatisfy({ $0.filter(isRussian).count * 2 > $0.count }) else { return [] }
        let protected = protectedWords(in: first, vocabulary: vocabulary)
        var changes: [SplitChange] = []
        for start in first.indices {
            for width in 1...min(3, first.count - start) {
                let old = start..<(start + width)
                let leftCount = old.upperBound == first.count ? 2 : 1
                let rightCount = old.lowerBound == 0 ? 2 : 1
                guard (old.lowerBound == 0 || old.lowerBound >= leftCount),
                      (old.upperBound == first.count || first.count - old.upperBound >= rightCount),
                      !(old.lowerBound == 0 && old.upperBound == first.count) else { continue }
                let left = old.lowerBound == 0 ? [] : Array(first[(old.lowerBound - leftCount)..<old.lowerBound])
                let right = old.upperBound == first.count ? [] : Array(first[old.upperBound..<(old.upperBound + rightCount)])
                guard splitMatches(in: first, left: left, right: right) == [old] else { continue }
                let alternatives = splitMatches(in: heard, left: left, right: right)
                guard alternatives.count == 1, let new = alternatives.first, old.count != new.count,
                      safeSplitContext(old, left: left, right: right, tokens: source, text: original),
                      safeSplitContext(new, left: left, right: right, tokens: evidence, text: corroboration) else { continue }
                let trimmed = trimmedSplit(old: old, new: new, source: first, evidence: heard)
                let before = Array(first[trimmed.old]), after = Array(heard[trimmed.new])
                guard !before.isEmpty, !after.isEmpty, before.count != after.count,
                      canChange(first, range: trimmed.old, protected: protected),
                      after.allSatisfy({ isReplaceable($0) && !affirmations.contains($0) }),
                      !before.contains(where: isNumberWord), !after.contains(where: isNumberWord),
                      splitSoundsCompatible(before, after) else { continue }
                // Trimming unchanged words must not hide a repeated immediate
                // anchor behind a wider, superficially unique context.
                let leftWidth = trimmed.old.upperBound == first.count ? 2 : 1
                let rightWidth = trimmed.old.lowerBound == 0 ? 2 : 1
                guard (trimmed.old.lowerBound == 0 || trimmed.old.lowerBound >= leftWidth),
                      (trimmed.old.upperBound == first.count || first.count - trimmed.old.upperBound >= rightWidth) else { continue }
                let immediateLeft = trimmed.old.lowerBound == 0 ? [] : Array(first[(trimmed.old.lowerBound - leftWidth)..<trimmed.old.lowerBound])
                let immediateRight = trimmed.old.upperBound == first.count ? [] : Array(first[trimmed.old.upperBound..<(trimmed.old.upperBound + rightWidth)])
                guard splitMatches(in: first, left: immediateLeft, right: immediateRight) == [trimmed.old],
                      splitMatches(in: heard, left: immediateLeft, right: immediateRight) == [trimmed.new] else { continue }
                changes.append(SplitChange(old: trimmed.old, new: trimmed.new, left: immediateLeft, right: immediateRight))
            }
        }
        return changes
    }

    private static func splitMatches(in words: [String], left: [String], right: [String]) -> [Range<Int>] {
        let edgeAnchor = left.isEmpty ? right : (right.isEmpty ? left : [])
        if !edgeAnchor.isEmpty {
            let occurrences = words.indices.filter { start in
                words[start...].starts(with: edgeAnchor)
            }
            guard occurrences.count == 1 else { return [] }
        }
        var matches: [Range<Int>] = []
        for start in words.indices {
            guard left.isEmpty ? start == 0 : start >= left.count && words[(start - left.count)..<start].elementsEqual(left) else { continue }
            for width in 1...min(3, words.count - start) {
                let end = start + width
                guard right.isEmpty ? end == words.count : end + right.count <= words.count && words[end..<(end + right.count)].elementsEqual(right) else { continue }
                matches.append(start..<end)
            }
        }
        return matches
    }

    private static func trimmedSplit(old: Range<Int>, new: Range<Int>, source: [String], evidence: [String]) -> (old: Range<Int>, new: Range<Int>) {
        let (a, b) = differingWords(Array(source[old]), Array(evidence[new]))
        return ((old.lowerBound + a.lowerBound)..<(old.lowerBound + a.upperBound),
                (new.lowerBound + b.lowerBound)..<(new.lowerBound + b.upperBound))
    }

    private static func wordRange(_ span: Range<Int>, tokens: [Token]) -> Range<String.Index> {
        tokens[span.lowerBound].range.lowerBound..<tokens[span.upperBound - 1].range.upperBound
    }

    private static func safeSplitContext(_ span: Range<Int>, left: [String], right: [String], tokens: [Token], text: String) -> Bool {
        let context = wordRange((span.lowerBound - left.count)..<(span.upperBound + right.count), tokens: tokens)
        let literalMarks = "/\\@_`#~"
        let adjacent = text[..<context.lowerBound].last.map(String.init) ?? ""
        let following = text[context.upperBound...].first.map(String.init) ?? ""
        guard !(adjacent + String(text[context]) + following).contains(where: literalMarks.contains),
              !intersectsLiteral(context, in: text), boundaryMarks(text[context]).isEmpty else { return false }
        let changed = text[wordRange(span, tokens: tokens)]
        return changed.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || $0 == "\t" || "-‐‑".contains($0) }
    }

    private static func splitSoundsCompatible(_ before: [String], _ after: [String]) -> Bool {
        let first = Array(before.joined()), second = Array(after.joined())
        guard min(first.count, second.count) >= 5, abs(first.count - second.count) <= 1 else { return false }
        for prefix in ["не", "ни", "без"] where String(first).hasPrefix(prefix) != String(second).hasPrefix(prefix) { return false }
        // Word boundaries may move, with at most one spelling letter changed.
        // This does not license synonyms, grammatical cleanup or phrase deletion.
        if first.count == second.count { return zip(first, second).filter { $0 != $1 }.count <= 1 }
        let longer = first.count > second.count ? first : second
        let shorter = first.count > second.count ? second : first
        let prefix = zip(longer, shorter).prefix { $0 == $1 }.count
        return longer.dropFirst(prefix + 1).elementsEqual(shorter.dropFirst(prefix))
    }

    /// A short disagreement at an utterance edge can have no second anchor.
    /// The unchanged remainder must be at least three words, and the changed
    /// words must remain acoustically close and contain no protected meaning.
    static func hasBoundaryDisagreement(original: String, corroboration: String, vocabulary: String) -> Bool {
        boundaryChange(original: original, corroboration: corroboration, vocabulary: vocabulary) != nil
    }

    /// Only call with a fresh, unprompted decode of the same audio. A glossary
    /// or neighboring sentence is never evidence for an unanchored edge.
    static func revisedBoundaryText(original: String, candidate: String, corroboration: String, vocabulary: String,
                                    establishedPhrases: Set<String> = [], expandedCorroboration: String? = nil) -> String? {
        guard MeetingSpeechText.accepts(candidate),
              let change = boundaryChange(original: original, corroboration: corroboration, vocabulary: vocabulary) else { return nil }
        let retry = tokens(candidate), evidence = tokens(corroboration)
        let source = tokens(original)
        guard retry.count == source.count, evidence.count == source.count,
              retry.indices.allSatisfy({ retry[$0].key == source[$0].key || retry[$0].key == evidence[$0].key }) else { return nil }
        let expandedText = expandedCorroboration ?? ""
        let expandedTokens = tokens(expandedText)
        let expanded = expandedTokens.map(\.key)
        let heard = evidence.map(\.key)
        let twiceHeard = MeetingSpeechText.accepts(expandedText) && expanded.count >= heard.count && expanded.indices.filter { start in
            guard start + heard.count <= expanded.count, expanded[start..<(start + heard.count)].elementsEqual(heard) else { return false }
            let interval = expandedTokens[start].range.lowerBound..<expandedTokens[start + heard.count - 1].range.upperBound
            return !intersectsLiteral(interval, in: expandedText)
        }.count == 1
        var edits: [(Range<String.Index>, String)] = []
        for index in change.old where source[index].key != evidence[index].key {
            guard !intersectsLiteral(retry[index].range, in: candidate) else { continue }
            if retry[index].key == evidence[index].key {
                edits.append((source[index].range, String(candidate[retry[index].range])))
            } else if twiceHeard, repeatedBoundaryOnset(at: index, source: source, evidence: evidence,
                                                       establishedPhrases: establishedPhrases) {
                edits.append((source[index].range, String(corroboration[evidence[index].range])))
            }
        }
        guard !edits.isEmpty else { return nil }
        var revised = original
        for (range, replacement) in edits.reversed() { revised.replaceSubrange(range, with: replacement) }
        return revised
    }

    static func needsBoundaryOnsetVerification(original: String, corroboration: String, vocabulary: String,
                                               establishedPhrases: Set<String>) -> Bool {
        guard let change = boundaryChange(original: original, corroboration: corroboration, vocabulary: vocabulary) else { return false }
        let source = tokens(original), evidence = tokens(corroboration)
        return change.old.contains { repeatedBoundaryOnset(at: $0, source: source, evidence: evidence,
                                                           establishedPhrases: establishedPhrases) }
    }

    static func hasBoundaryOnsetShape(original: String, corroboration: String) -> Bool {
        let source = tokens(original), evidence = tokens(corroboration)
        guard source.count == evidence.count else { return false }
        return source.indices.contains { repeatedBoundaryOnset(at: $0, source: source, evidence: evidence, establishedPhrases: nil) }
    }

    private static func repeatedBoundaryOnset(at index: Int, source: [Token], evidence: [Token],
                                              establishedPhrases: Set<String>?) -> Bool {
        guard index > 0, index + 1 < source.count,
              source[index].key.count >= 5, evidence[index].key.count >= 4,
              let consonant = source[index].key.first, "бвгджзклмнпрстфхцчшщ".contains(consonant),
              source[index - 1].key == evidence[index - 1].key,
              source[index - 1].key.last(where: { !"ьъ".contains($0) }) == consonant,
              String(source[index].key.dropFirst()) == evidence[index].key,
              source[index + 1].key == evidence[index + 1].key else { return false }
        return establishedPhrases?.contains(evidence[index].key + " " + evidence[index + 1].key) ?? true
    }

    private static func boundaryChange(original: String, corroboration: String, vocabulary: String) -> (old: Range<Int>, new: Range<Int>)? {
        guard MeetingSpeechText.accepts(original), MeetingSpeechText.accepts(corroboration) else { return nil }
        let source = tokens(original), evidence = tokens(corroboration)
        let first = source.map(\.key), heard = evidence.map(\.key)
        let (old, new) = differingWords(first, heard)
        guard (1...3).contains(old.count), old.count == new.count,
              (old.lowerBound <= 2 && first.count - old.upperBound >= 3)
                || (first.count - old.upperBound <= 2 && old.lowerBound >= 3),
              first.filter(isRussian).count * 2 > first.count,
              heard.filter(isRussian).count * 2 > heard.count,
              canChange(first, range: old, protected: protectedWords(in: first, vocabulary: vocabulary)),
              heard[new].allSatisfy({ isReplaceable($0) && !affirmations.contains($0) }),
              !first[old].contains(where: isNumberWord), !heard[new].contains(where: isNumberWord) else { return nil }
        let previousWords: [String] = Array(first[old])
        let proposedWords: [String] = Array(heard[new])
        let negativePrefixes: [String] = ["не", "ни", "без"]
        for pair in zip(previousWords, proposedWords) {
            let before: String = pair.0
            let after: String = pair.1
            for prefix in negativePrefixes {
                let prefixedBefore: String = prefix + before
                let prefixedAfter: String = prefix + after
                if before == prefixedAfter || after == prefixedBefore { return nil }
            }
        }
        guard soundsCompatible(previousWords, proposedWords) else { return nil }
        let oldRange = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
        let newRange = evidence[new.lowerBound].range.lowerBound..<evidence[new.upperBound - 1].range.upperBound
        guard !intersectsLiteral(oldRange, in: original), !intersectsLiteral(newRange, in: corroboration) else { return nil }
        return (old, new)
    }

    /// Omitting a subject, condition, negation or amount at an acoustic cut
    /// can reverse the meaning even when the following words agree.
    static func isSensitiveAtCut(_ word: String) -> Bool {
        meaningMarkers.contains(word) || ["если", "якобы", "возможно", "наверное", "вероятно",
            "невозможно", "запрещено", "разрешено", "можно"].contains(word)
            || word.contains(where: \.isNumber) || isNumberWord(word) || TranscriptTerms.isKnownEntityForm(word)
    }

    static func isNumberWord(_ word: String) -> Bool {
        // Cardinal/ordinal stems include Russian case forms and compound
        // quantities. Over-protection here only skips an optional reread.
        let stems = ["нол", "нул", "один", "одн", "два", "две", "двух", "двум", "три", "трех", "трем", "тремя",
            "четыр", "пят", "шест", "семь", "семи", "семью", "восем", "восьм", "девят", "десят",
            "одиннадц", "двенадц", "тринадц", "четырнадц", "пятнадц", "шестнадц", "семнадц", "восемнадц", "девятнадц",
            "двадц", "тридц", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяност",
            "сто", "ста", "сот", "двести", "двухсот", "триста", "трехсот", "тысяч", "миллион", "миллиард", "триллион",
            "перв", "втор", "трет", "четверт", "седьм", "полтор", "полутор", "половин",
            "оба", "обе", "обои", "двое", "двоих", "двоим", "трое", "троих", "троим", "четверо", "четверых"]
        return stems.contains(where: word.hasPrefix)
    }

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

    // Preserve quantity units and symbols against local deletion or duplication.
    // Symbols must also be tokens: otherwise a prefix "$" can fall outside a
    // span anchored on the number, silently deleting its spoken currency unit.
    // This does not establish equivalence or protect all spelled-out amounts.
    private static let quantityUnits: Set<String> = [
        "доллар", "доллара", "доллару", "долларом", "долларе", "доллары", "долларов", "долларам", "долларами", "долларах",
        "рубль", "рубля", "рублю", "рублем", "рубле", "рубли", "рублей", "рублям", "рублями", "рублях",
        "евро", "цент", "цента", "центу", "центом", "центе", "центы", "центов", "центам", "центами", "центах",
        "фунт", "фунта", "фунту", "фунтом", "фунте", "фунты", "фунтов", "фунтам", "фунтами", "фунтах",
        "юань", "юаня", "юаню", "юанем", "юане", "юани", "юаней", "юаням", "юанями", "юанях",
        "процент", "процента", "проценту", "процентом", "проценте", "проценты", "процентов", "процентам", "процентами", "процентах", "промилле"
    ]

    private static func isReplaceable(_ word: String) -> Bool {
        isRussian(word) && !meaningMarkers.contains(word) && !quantityUnits.contains(word)
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
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { term -> [String] in
                var forms = [term] + RecognitionVocabulary.cyrillicInflections(of: term)
                // Protect regular case forms of explicit я-ending names too.
                if term.count >= 3, term.first?.isUppercase == true, term.dropFirst().allSatisfy(\.isLowercase),
                   term.hasSuffix("я"), isRussian(term.lowercased().replacingOccurrences(of: "ё", with: "е")) {
                    forms += ["и", "е", "ю", "ей", "ею", "ям", "ями", "ях"].map { String(term.dropLast()) + $0 }
                }
                return forms
            }
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
