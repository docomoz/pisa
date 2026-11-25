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
        let suffixes = Set(AbbreviationFamilies.caseEndings)
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

    fileprivate enum CyrillicConfirmation {
        case letters(changedWords: Set<Int>)
        case mixedTurn(original: String)
        case anchoredPhrase([String])
        case exactWords
    }

    struct CyrillicSpellingRepair {
        let text: String
        let confirmedByRepetition: Bool
        fileprivate let confirmation: CyrillicConfirmation

        func confirmedText(language: String?, reread: String) -> String? {
            guard language?.lowercased() == "russian" else { return nil }
            let candidate = words(text), checked = words(reread)
            if case .anchoredPhrase(let phrase) = confirmation {
                let matches = checked.indices.filter { checked[$0...].starts(with: phrase) }
                guard matches.count == 1, let start = matches.first else { return nil }
                let read = tokens(in: reread)
                let range = read[start].range.lowerBound..<read[start + phrase.count - 1].range.upperBound
                guard reread[range].allSatisfy({ $0.isLetter || $0 == " " || "-‐‑".contains($0) }),
                      !TranscriptOrthography.literalRanges(in: reread).contains(where: { NSIntersectionRange($0, NSRange(range, in: reread)).length > 0 }) else { return nil }
                return text
            }
            if candidate == checked { return text }
            switch confirmation {
            case .letters(let changedWords):
                // Keep a preposition or particle heard by both other models
                // when Qwen heard every corrected word but omitted that token.
                guard checked.count >= 3, candidate.count == checked.count + 1 else { return nil }
                let omitted = zip(candidate, checked).prefix(while: { $0 == $1 }).count
                guard !changedWords.contains(omitted), AbbreviationFamilies.isRussianFunctionWord(candidate[omitted]),
                      candidate.dropFirst(omitted + 1).elementsEqual(checked.dropFirst(omitted)) else { return nil }
                return text
            case .anchoredPhrase, .exactWords:
                return nil
            case .mixedTurn(let original):
                if agreesApartFromHesitation(candidate, checked) { return text }
                // If the sole disagreement is a spelling already present in the
                // primary, keep that spelling and the original punctuation.
                let source = tokens(in: original), heard = tokens(in: text)
                guard source.count == heard.count, candidate.count == checked.count else { return nil }
                let mismatch = candidate.indices.filter { candidate[$0] != checked[$0] }
                guard mismatch.count == 1, let index = mismatch.first,
                      source[index].key == checked[index], withinOneEdit(candidate[index], checked[index]),
                      isCyrillic(checked[index]), checked[index].count >= 4 else { return nil }
                let revised = NSMutableString(string: original)
                for i in source.indices.reversed() where source[i].key != checked[i] {
                    guard source[i].text.allSatisfy(\.isLowercase), heard[i].text.allSatisfy(\.isLowercase) else { return nil }
                    revised.replaceCharacters(in: NSRange(source[i].range, in: original), with: heard[i].text)
                }
                return revised as String
            }
        }
    }

    // A short hesitation can be heard differently. Require agreement around
    // it and on every substantive word before choosing the acoustic reading.
    private static let hesitationWords: Set<String> = ["же", "тоже", "также", "ну", "вот"]

    private static func agreesApartFromHesitation(_ candidate: [String], _ checked: [String]) -> Bool {
        let prefix = zip(candidate, checked).prefix(while: { $0 == $1 }).count
        let suffix = zip(candidate.dropFirst(prefix).reversed(), checked.dropFirst(prefix).reversed())
            .prefix(while: { $0 == $1 }).count
        guard prefix >= 2, suffix >= 2, prefix + suffix >= 8 else { return false }
        let candidateGap = candidate[prefix..<(candidate.count - suffix)]
        let checkedGap = checked[prefix..<(checked.count - suffix)]
        return isHesitation(candidateGap) && isHesitation(checkedGap)
    }

    private static func isHesitation(_ words: ArraySlice<String>) -> Bool {
        guard words.count <= 2 else { return false }
        return words.elementsEqual(["то", "есть"]) || words.elementsEqual(["что", "то"])
            || words.allSatisfy(hesitationWords.contains)
    }

    // Intact Russian adjective and verb endings can distinguish a damaged
    // Russian word from a real code switch such as “Привіт, привет”.
    private static let russianInflections = ["его", "ые", "ыми", "ешь", "ишь"]

    static func cyrillicSpelling(original: String, heard: String, vocabulary: String) -> CyrillicSpellingRepair? {
        guard ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(original) else { return nil }
        return letterSpelling(original: original, heard: heard, vocabulary: vocabulary)
            ?? mixedCyrillicSpelling(original: original, heard: heard, vocabulary: vocabulary)
            ?? anchoredCyrillicSpelling(original: original, heard: heard, vocabulary: vocabulary)
    }

    // Parakeet can mix scripts within an otherwise Russian word, or spell
    // the conjunction with Cyrillic І. A Latin I by itself can be a numeral.
    private static let suspectI = try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}])i(?=[а-яё])"#)

    static func needsScriptSpellingCheck(_ text: String) -> Bool {
        ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(text)
            || (text.contains("I") || text.contains("i"))
                && suspectI.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func russianLetters(_ word: String) -> String {
        String(word.map { letter in
            switch letter {
            case "і", "ї", "i": return "и"
            case "І", "Ї", "I": return "И"
            case "є": return "е"
            case "Є": return "Е"
            default: return letter
            }
        })
    }

    /// Dialogue only. Quotes, paths, abbreviations with digits and mixed-script
    /// names have other contracts and cannot license an edit to the whole turn.
    static func isCyrillicSpeech(_ text: String) -> Bool {
        ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(text)
            && text.unicodeScalars.allSatisfy {
                (0x400...0x52F).contains($0.value) || CharacterSet.whitespacesAndNewlines.contains($0)
                    || ",.!?…-‐‑–—".unicodeScalars.contains($0)
            }
            && TranscriptOrthography.literalRanges(in: text).isEmpty
    }

    enum CyrillicAudioReading: Equatable {
        case source, russian(String), disputed
    }

    /// Compare the exact same unprompted audio in a multilingual and a Russian
    /// decoder. A sentence can start or end with the damaged span. Every edit
    /// must agree in its own position even when other parts of the two reads differ.
    static func cyrillicAudioReading(original: String, reread: String, language: String?,
                                     heard: String?, vocabulary: String, isolatedPrimary: () -> String? = { nil }) -> CyrillicAudioReading? {
        guard isCyrillicSpeech(original) else { return nil }
        let detected = language?.lowercased()
        if (["ukrainian", "belarusian"].contains(detected ?? "") && reread.unicodeScalars.contains(where: { (0x400...0x52F).contains($0.value) }))
            || BackchannelLanguage.confirmsCyrillicSource(original: original, reread: reread, language: language) { return .source }
        guard let heard, !heard.isEmpty else { return nil }
        if detected != "russian", let detected, detected != "none", !reread.isEmpty,
           words(original).count == 1, BackchannelLanguage.isLatinSpeech(reread),
           ParakeetRecognitionPolicy.hasRussianTextEvidence(heard),
           preservesVocabulary(candidate: "", original: original, vocabulary: vocabulary) { return .disputed }
        guard detected == "russian", !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(reread),
              !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(heard),
              ParakeetRecognitionPolicy.hasRussianTextEvidence(reread), ParakeetRecognitionPolicy.hasRussianTextEvidence(heard),
              TranscriptOrthography.literalRanges(in: reread).isEmpty else { return nil }
        var verifiedText = reread
        let read = words(reread), acoustic = words(heard)
        if read.count >= 2, read.count == acoustic.count {
            let different = read.indices.filter { read[$0] != acoustic[$0] }
            if different.count == 1, let i = different.first, min(read[i].count, acoustic[i].count) >= 5,
               distance(read[i], acoustic[i]) <= 2, let primary = isolatedPrimary(),
               words(primary) == acoustic { verifiedText = primary }
        }
        let source = tokens(in: original), checked = tokens(in: verifiedText)
        guard (1...100).contains(source.count), (1...120).contains(checked.count), !acoustic.isEmpty else { return nil }
        let before = source.map(\.key)
        var after = checked.map(\.key)
        let protected = TranscriptOrthography.glossaryRanges(in: original, vocabulary: vocabulary,
            range: NSRange(original.startIndex..., in: original))
        let originalAnchors = alignedWords(before, after)
        let anchors: [(Int, Int)]
        if before.count >= 4, before.count == after.count, after.count == acoustic.count,
           originalAnchors.allSatisfy({ $0.0 == $0.1 }),
           before.indices.filter({ before[$0] == acoustic[$0] }).count * 2 > before.count,
           after.indices.filter({ after[$0] == acoustic[$0] }).count * 4 >= after.count * 3,
           [before, after].allSatisfy({ alignedWords($0, acoustic).allSatisfy { $0.0 == $0.1 } }) {
            // The primary and acoustic model can agree on a term next to the
            // damage while the multilingual model misses one letter. Keep
            // that word from the source as a boundary, never as a replacement.
            for i in before.indices where before[i] == acoustic[i] && before[i] != after[i]
                && min(before[i].count, after[i].count) >= 4 && withinOneEdit(before[i], after[i]) {
                after[i] = before[i]
            }
            anchors = before.indices.compactMap { before[$0] == after[$0] ? ($0, $0) : nil }
        } else {
            anchors = originalAnchors
        }
        let edges = [(-1, -1)] + anchors + [(before.count, after.count)]
        // A shared-alphabet syllable can repeat both beside and apart from
        // the visibly damaged word. Reuse only a positionally verified pair.
        var repeatedPairs = Set<[String]>()
        for (left, right) in zip(edges, edges.dropFirst()) {
            let old = (left.0 + 1)..<right.0, new = (left.1 + 1)..<right.1
            guard old.count == new.count, old.count > 1, before[old].contains(where: ParakeetRecognitionPolicy.hasDistinctCyrillicLetters),
                  acoustic.indices.contains(where: { acoustic[$0...].starts(with: after[new]) }) else { continue }
            for (a, b) in zip(before[old], after[new]) where a.count <= 3 && withinOneEdit(a, b) {
                repeatedPairs.insert([a, b])
            }
        }
        let result = NSMutableString(string: original)
        let sensitive: Set<String> = ["не", "ни", "ні", "нет", "нельзя", "никогда", "без", "или", "либо"]
        func unique(_ phrase: ArraySlice<String>, in words: [String]) -> Bool {
            words.indices.filter { words[$0...].starts(with: phrase) }.count == 1
        }
        func cased(_ replacement: String, like sourceWord: String) -> String {
            guard let first = replacement.first, sourceWord.first?.isUppercase == true else { return replacement }
            return first.uppercased() + replacement.dropFirst()
        }
        for (left, right) in zip(edges, edges.dropFirst()).reversed() {
            let old = (left.0 + 1)..<right.0, new = (left.1 + 1)..<right.1
            guard !old.isEmpty, !new.isEmpty else { continue }
            let originalWord = before[old.lowerBound], checkedWord = after[new.lowerBound]
            let shortFunction = old.count == 1 && new.count == 1 && repeatedPairs.contains([originalWord, checkedWord])
            // Both decoders may join a detached без- prefix to the damaged
            // following word. A separate negative particle remains protected.
            let joinedPrefix = old.count == 2 && new.count == 1 && originalWord == "без"
                && (checkedWord.hasPrefix("бес") || checkedWord.hasPrefix("без")) && checkedWord.count >= 7
                && distance(russianLetters(before[old].joined()), checkedWord) <= 3
            guard shortFunction || before[old].contains(where: ParakeetRecognitionPolicy.hasDistinctCyrillicLetters),
                  joinedPrefix || before[old].filter(sensitive.contains) == after[new].filter(sensitive.contains),
                  before[old].filter(RecognitionConsensus.isNumberWord) == after[new].filter(RecognitionConsensus.isNumberWord),
                  after[new].allSatisfy(isCyrillic),
                  abs(old.count - new.count) <= max(2, old.count / 2) else { continue }
            let oldRange = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
            let newRange = checked[new.lowerBound].range.lowerBound..<checked[new.upperBound - 1].range.upperBound
            let nsRange = NSRange(oldRange, in: original)
            guard !protected.contains(where: { NSIntersectionRange($0, nsRange).length > 0 }),
                  [original[oldRange], verifiedText[newRange]].allSatisfy({ $0.allSatisfy { letter in
                      letter.isLetter || letter.isWhitespace || ",-‐‑".contains(letter)
                  } }),
                  !old.contains(where: { i in
                      guard source[i].text.first?.isUppercase == true, i > 0 else { return false }
                      return !original[source[i - 1].range.upperBound..<source[i].range.lowerBound].contains(where: { ".!?…".contains($0) })
                  }) else { continue }
            let leftWidth = left.0 >= 0 ? 1 : 0, rightWidth = right.0 < source.count ? 1 : 0
            let phrase = after[(new.lowerBound - leftWidth)..<(new.upperBound + rightWidth)]
            // Without an anchor on one side, the two reads must place the
            // changed phrase on the same physical edge of the turn.
            guard unique(before[(old.lowerBound - leftWidth)..<(old.upperBound + rightWidth)], in: before),
                  unique(phrase, in: after), unique(phrase, in: acoustic),
                  leftWidth > 0 || acoustic.starts(with: phrase),
                  rightWidth > 0 || acoustic.suffix(phrase.count).elementsEqual(phrase) else { continue }
            if leftWidth == 0 && rightWidth == 0 {
                guard acoustic == after, similarLength(before, after) else { continue }
            }
            // Keep the source's commas, hesitations and emphasis when tokens align.
            if old.count == new.count {
                for (i, j) in zip(old, new).reversed() where before[i] != after[j] {
                    result.replaceCharacters(in: NSRange(source[i].range, in: original),
                        with: cased(checked[j].text, like: source[i].text))
                }
            } else {
                result.replaceCharacters(in: nsRange, with: cased(String(verifiedText[newRange]), like: source[old.lowerBound].text))
            }
        }
        let repaired = result as String
        let named = source.indices.dropFirst().contains { i in
            source[i].text.first?.isUppercase == true
                && !original[source[i - 1].range.upperBound..<source[i].range.lowerBound].contains(where: { ".!?…".contains($0) })
        }
        if ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(repaired), source.count >= 4, protected.isEmpty, !named,
           let partial = corroboratedCyrillicFragments(source: source, read: verifiedText, checked: checked, acoustic: acoustic,
                sensitive: sensitive), preservesVocabulary(candidate: partial, original: original, vocabulary: vocabulary) {
            return .russian(partial)
        }
        if repaired != original { return .russian(repaired) }
        // Keep an entire substantive sentence available for narrower repairs.
        // Only a disputed, isolated word can become unclear in Russian context.
        return source.count == 1 && protected.isEmpty ? .disputed : nil
    }

    private static func alignedWords(_ left: [String], _ right: [String]) -> [(Int, Int)] {
        let difference = right.difference(from: left)
        let removed = Set(difference.removals.compactMap { if case .remove(let i, _, _) = $0 { return i }; return nil })
        let inserted = Set(difference.insertions.compactMap { if case .insert(let i, _, _) = $0 { return i }; return nil })
        return Array(zip(left.indices.filter { !removed.contains($0) }, right.indices.filter { !inserted.contains($0) }))
    }

    private static func corroboratedCyrillicFragments(source: [Token], read: String, checked: [Token],
                                                      acoustic: [String], sensitive: Set<String>) -> String? {
        let original = source.map(\.key), keys = checked.map(\.key)
        guard similarLength(original, keys), similarLength(acoustic, keys), keys.allSatisfy(isCyrillic) else { return nil }
        // Retain an original Russian word which the multilingual decoder
        // also heard unchanged when the acoustic decoder differs only in its
        // ending beside a shared anchor. This word is never a new insertion.
        let sourceAlignment = alignedWords(original, keys)
        let sourceMatches = Set(sourceAlignment.map { $0.1 })
        var comparable = acoustic
        for (a, b) in alignedWords(keys, acoustic) {
            for direction in [-1, 1] {
                let k = a + direction, h = b + direction
                guard keys.indices.contains(k), acoustic.indices.contains(h), sourceMatches.contains(k),
                      keys[k] != acoustic[h], keys[k].count >= 5, keys[k].prefix(4) == acoustic[h].prefix(4),
                      withinOneEdit(keys[k], acoustic[h]), TranscriptTerms.isCommonRussianWord(keys[k]),
                      TranscriptTerms.isCommonRussianWord(acoustic[h]) else { continue }
                comparable[h] = keys[k]
            }
        }
        let pairs = alignedWords(keys, comparable)
        var runs: [[(Int, Int)]] = []
        for pair in pairs {
            if let last = runs.last?.last, pair.0 == last.0 + 1 && pair.1 == last.1 + 1 {
                runs[runs.count - 1].append(pair)
            } else { runs.append([pair]) }
        }
        let confirmed = runs.filter { run in
            let phrase = run.map { keys[$0.0] }
            let content = phrase.contains { $0.count >= 4 && TranscriptTerms.isCommonRussianWord($0) }
                || (phrase.count >= 3 && phrase.allSatisfy(TranscriptTerms.isCommonRussianWord))
            let quantity = phrase.contains(where: RecognitionConsensus.isNumberWord)
            return (phrase.count >= 2 && content || quantity)
                && [keys, comparable].allSatisfy { sequence in sequence.indices.filter { sequence[$0...].starts(with: phrase) }.count == 1 }
        }
        guard let first = confirmed.first?.first, let last = confirmed.last?.last,
              confirmed.contains(where: { $0.count >= 3 || ($0.count == 2 && $0.first?.0 == 0 && $0.first?.1 == 0) }) else { return nil }
        let retained = confirmed.flatMap { $0.map { $0.0 } }
        guard retained.count * 2 > max(original.count, max(keys.count, acoustic.count)) else { return nil }
        // An unchanged introduction can be heard perfectly even when the decoders
        // disagree about every damaged word. Require a corroborated spelling in
        // the corresponding gap of the source, before discarding any of its words.
        let edges = [(-1, -1)] + sourceAlignment + [(original.count, keys.count)]
        let repairsSpelling = zip(edges, edges.dropFirst()).contains { left, right in
            let old = (left.0 + 1)..<right.0, new = (left.1 + 1)..<right.1
            return retained.contains { i in
                new.contains(i) && old.contains { j in
                    let word = original[j]
                    let length = min(word.count, keys[i].count)
                    guard length >= 3, ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(word),
                          old.count != new.count || i - new.lowerBound == j - old.lowerBound else { return false }
                    let tolerance = min(4, (length - 1) / 2)
                    return abs(word.count - keys[i].count) <= tolerance && distance(russianLetters(word), keys[i]) <= tolerance
                }
            }
        }
        guard repairsSpelling else { return nil }
        let kept = retained.map { keys[$0] }
        let names = Set(source.filter { $0.text.first?.isUppercase == true && TranscriptTerms.isKnownEntityForm($0.key) }.map(\.key))
        let important: (String) -> Bool = { sensitive.contains($0) || RecognitionConsensus.isNumberWord($0) || names.contains($0) }
        guard original.filter(important) == kept.filter(important),
              original.filter({ $0.count >= 4 && keys.contains($0) && TranscriptTerms.isCommonRussianWord($0) }).allSatisfy(kept.contains)
        else { return nil }
        var pieces = confirmed.map { run in
            String(read[checked[run[0].0].range.lowerBound..<checked[run[run.count - 1].0].range.upperBound])
        }
        let missingStart = first.0 > 0 || first.1 > 0
        let missingEnd = last.0 + 1 < keys.count || last.1 + 1 < acoustic.count
        guard pieces.count > 1 || missingStart || missingEnd else { return nil }
        if missingStart {
            if first.0 == 0, first.1 == 1, let leading = original.first, acoustic.first == leading,
               AbbreviationFamilies.isRussianFunctionWord(leading), !sensitive.contains(leading) {
                pieces[0] = leading.capitalized + " " + pieces[0].prefix(1).lowercased() + pieces[0].dropFirst()
            } else { pieces[0] = "… " + pieces[0] }
        }
        return pieces.joined(separator: " … ") + (missingEnd ? "…" : "")
    }

    /// A clipped beginning can differ between decoders while both agree on
    /// the damaged word and each of its immediate neighbors.
    static func shortCyrillicSpelling(original: String, reread: String, heard: String) -> String? {
        guard ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(original) else { return nil }
        let source = tokens(in: original), checked = tokens(in: reread)
        guard (3...12).contains(source.count), source.count == checked.count else { return nil }
        let changes = source.indices.filter { source[$0].key != checked[$0].key }
        guard changes.count == 1, let i = changes.first, i > 0, i + 1 < source.count,
              ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(source[i].key),
              checked[i].key.count >= 3, TranscriptTerms.isCommonRussianWord(checked[i].key),
              withinOneEdit(russianLetters(source[i].key), checked[i].key) else { return nil }
        let evidence = words(heard), phrase = checked[(i - 1)...(i + 1)].map(\.key)
        guard evidence.indices.filter({ evidence[$0...].starts(with: phrase) }).count == 1 else { return nil }
        return original.replacingCharacters(in: source[i].range, with: checked[i].text)
    }

    /// Keep punctuation and all unrelated words from the primary. Agreement
    /// on a unique adjacent pair in both independent decodes suffices even
    /// when a stutter or different wording prevents whole-turn alignment.
    struct LocalScriptRepair {
        fileprivate struct Edit {
            let range: NSRange
            let spelling: String
            let pairs: [String]
        }
        fileprivate let original: String
        fileprivate let edits: [Edit]

        func confirmedText(language: String?, reread: String) -> String? {
            guard language?.lowercased() == "russian" else { return nil }
            let pairs = adjacentWordPairs(in: reread, tokens: tokens(in: reread))
            let unique = uniquePairs(pairs)
            let revised = NSMutableString(string: original)
            for edit in edits.reversed() where !unique.isDisjoint(with: edit.pairs) {
                revised.replaceCharacters(in: edit.range, with: edit.spelling)
            }
            return revised as String == original ? nil : revised as String
        }
    }

    // Each entry corresponds to the gap after the token at that index. Do
    // not use words across sentence boundaries, links or quotations as anchors.
    private static func adjacentWordPairs(in text: String, tokens: [Token], repairLetters: Bool = false) -> [String?] {
        let literals = TranscriptOrthography.literalRanges(in: text)
        return zip(tokens, tokens.dropFirst()).map { left, right in
            let gap = text[left.range.upperBound..<right.range.lowerBound]
            let span = NSRange(left.range.lowerBound..<right.range.upperBound, in: text)
            guard !gap.isEmpty, gap.allSatisfy({ $0 == "," || ($0.isWhitespace && !$0.isNewline) }),
                  !literals.contains(where: { NSIntersectionRange($0, span).length > 0 }) else { return nil }
            let pair = left.key + " " + right.key
            return repairLetters ? russianLetters(pair) : pair
        }
    }

    private static func uniquePairs(_ pairs: [String?]) -> Set<String> {
        let grouped = Dictionary(grouping: pairs.compactMap { $0 }, by: { $0 })
        return Set(grouped.compactMap { $0.value.count == 1 ? $0.key : nil })
    }

    static func localScriptSpelling(original: String, heard: String, vocabulary: String) -> LocalScriptRepair? {
        let source = tokens(in: original)
        let pairs = adjacentWordPairs(in: original, tokens: source, repairLetters: true)
        let sourcePairs = uniquePairs(pairs)
        let heardPairs = uniquePairs(adjacentWordPairs(in: heard, tokens: tokens(in: heard)))
        let glossary = TranscriptOrthography.glossaryRanges(in: original, vocabulary: vocabulary, range: NSRange(original.startIndex..., in: original))
        let attached = "_/@\\-‐‑'’+#"
        var edits: [LocalScriptRepair.Edit] = []
        for (i, token) in source.enumerated() {
            let spelling = russianLetters(token.text)
            guard spelling != token.text, needsScriptSpellingCheck(token.text),
                  token.key == "і" || token.key.count >= 3,
                  TranscriptTerms.isCommonRussianWord(russianLetters(token.key)) || token.key == "і",
                  original[..<token.range.lowerBound].last.map(attached.contains) != true,
                  original[token.range.upperBound...].first.map(attached.contains) != true else { continue }
            let range = NSRange(token.range, in: original)
            guard !glossary.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
            let anchors = [i - 1, i + 1].compactMap { neighbor -> String? in
                guard source.indices.contains(neighbor), source[neighbor].key.count >= 2,
                      TranscriptTerms.isCommonRussianWord(source[neighbor].key),
                      let pair = pairs[min(i, neighbor)],
                      sourcePairs.contains(pair), heardPairs.contains(pair) else { return nil }
                return pair
            }
            if !anchors.isEmpty { edits.append(.init(range: range, spelling: spelling, pairs: anchors)) }
        }
        return edits.isEmpty ? nil : LocalScriptRepair(original: original, edits: edits)
    }

    /// When the recognizers disagree elsewhere in a mixed turn, recover a
    /// damaged phrase between words occurring just once in each audio reading.
    private static func anchoredCyrillicSpelling(original: String, heard: String, vocabulary: String,
                                                 sharedAlphabet: Bool = false) -> CyrillicSpellingRepair? {
        let source = tokens(in: original), evidence = tokens(in: heard)
        guard !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(heard) else { return nil }
        if sharedAlphabet {
            guard source.count >= 7, abs(source.count - evidence.count) <= 3 else { return nil }
        } else {
            guard source.filter({ ParakeetRecognitionPolicy.hasDistinctCyrillicLetters($0.key) }).count >= 2 else { return nil }
        }
        let primaryPositions = Dictionary(grouping: source.indices, by: { source[$0].key })
        let heardPositions = Dictionary(grouping: evidence.indices, by: { evidence[$0].key })
        let anchors = source.indices.compactMap { i -> (source: Int, heard: Int)? in
            let key = source[i].key
            guard primaryPositions[key]?.count == 1, let positions = heardPositions[key], positions.count == 1,
                  TranscriptTerms.isCommonRussianWord(key) || AbbreviationFamilies.isRussianFunctionWord(key) else { return nil }
            return (i, positions[0])
        }
        guard anchors.count >= (sharedAlphabet ? 6 : 3),
              zip(anchors, anchors.dropFirst()).allSatisfy({ $0.heard < $1.heard }) else { return nil }
        let protected = TranscriptOrthography.literalRanges(in: original)
            + TranscriptOrthography.glossaryRanges(in: original, vocabulary: vocabulary, range: NSRange(original.startIndex..., in: original))
        var repairs: [CyrillicSpellingRepair] = []
        for (left, right) in zip(anchors, anchors.dropFirst()) {
            let old = (left.source + 1)..<right.source, new = (left.heard + 1)..<right.heard
            guard (1...4).contains(old.count), (1...5).contains(new.count),
                  source[old].allSatisfy({ $0.text.allSatisfy(\.isLowercase) && $0.key.unicodeScalars.allSatisfy { (0x400...0x52F).contains($0.value) } }),
                  evidence[new].allSatisfy({ $0.text.allSatisfy(\.isLowercase) && TranscriptTerms.isCommonRussianWord($0.key) }) else { continue }
            if sharedAlphabet {
                let spelling = source[old.lowerBound].key, candidate = evidence[new.lowerBound].key
                guard old.count == 1, new.count == 1, (2...3).contains(spelling.count), (2...4).contains(candidate.count),
                      isCyrillic(spelling), !TranscriptTerms.isCommonRussianWord(spelling),
                      !Set(spelling).isDisjoint(with: candidate), distance(spelling, candidate) <= 2 else { continue }
            } else {
                guard source[old].contains(where: { ParakeetRecognitionPolicy.hasDistinctCyrillicLetters($0.key) }) else { continue }
            }
            let range = source[old.lowerBound].range.lowerBound..<source[old.upperBound - 1].range.upperBound
            let originalContext = original[source[left.source].range.upperBound..<source[right.source].range.lowerBound]
            let acousticContext = heard[evidence[left.heard].range.upperBound..<evidence[right.heard].range.lowerBound]
            guard isSpellingRepairContext(originalContext), isSpellingRepairContext(acousticContext),
                  !protected.contains(where: { NSIntersectionRange($0, NSRange(range, in: original)).length > 0 }) else { continue }
            let replacement = heard[evidence[new.lowerBound].range.lowerBound..<evidence[new.upperBound - 1].range.upperBound]
            var result = original
            result.replaceSubrange(range, with: replacement)
            let phrase = evidence[left.heard...right.heard].map(\.key)
            repairs.append(CyrillicSpellingRepair(text: result, confirmedByRepetition: false, confirmation: .anchoredPhrase(phrase)))
        }
        return repairs.count == 1 ? repairs[0] : nil
    }

    private static func isSpellingRepairContext(_ phrase: Substring) -> Bool {
        guard phrase.first == " ", phrase.last == " " else { return false }
        return phrase.allSatisfy { (character: Character) in
            character.isLetter || character == " " || "-‐‑".contains(character)
        }
    }

    /// A shared-alphabet error such as "гатовы" carries no script signal.
    /// Prefer full agreement. If a hesitation disrupts alignment elsewhere,
    /// require a unique, locally confirmed word in a longer Russian turn.
    static func sharedAlphabetSpelling(original: String, heard: String, vocabulary: String) -> CyrillicSpellingRepair? {
        exactSharedAlphabetSpelling(original: original, heard: heard, vocabulary: vocabulary)
            ?? anchoredCyrillicSpelling(original: original, heard: heard, vocabulary: vocabulary, sharedAlphabet: true)
    }

    private static func exactSharedAlphabetSpelling(original: String, heard: String, vocabulary: String) -> CyrillicSpellingRepair? {
        let source = tokens(in: original), independent = tokens(in: heard)
        guard source.count >= 3, source.count == independent.count else { return nil }
        let changed = source.indices.filter { source[$0].key != independent[$0].key }
        guard changed.count == 1, let i = changed.first, i > 0, i + 1 < source.count else { return nil }
        let token = source[i], replacement = independent[i]
        let closeForm = token.key.count >= 4 && replacement.key.count >= 4 && withinOneEdit(token.key, replacement.key)
        let shortFunctionWord = (2...3).contains(token.key.count) && AbbreviationFamilies.isRussianFunctionWord(replacement.key)
            && token.key.last == replacement.key.last && distance(token.key, replacement.key) <= 2
        guard closeForm || shortFunctionWord,
              token.text.allSatisfy(\.isLowercase), replacement.text.allSatisfy(\.isLowercase),
              isCyrillic(token.key), isCyrillic(replacement.key),
              !TranscriptTerms.isCommonRussianWord(token.key), TranscriptTerms.isCommonRussianWord(replacement.key),
              [source[i - 1], source[i + 1]].allSatisfy({ TranscriptTerms.isCommonRussianWord($0.key) }),
              original[source[i - 1].range.upperBound..<token.range.lowerBound].allSatisfy(\.isWhitespace),
              original[token.range.upperBound..<source[i + 1].range.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
        let tokenRange = NSRange(token.range, in: original)
        let protected = TranscriptOrthography.literalRanges(in: original)
            + TranscriptOrthography.glossaryRanges(in: original, vocabulary: vocabulary, range: NSRange(original.startIndex..., in: original))
        guard !protected.contains(where: { NSIntersectionRange($0, tokenRange).length > 0 }) else { return nil }
        var revised = original
        revised.replaceSubrange(token.range, with: replacement.text)
        return CyrillicSpellingRepair(text: revised, confirmedByRepetition: false, confirmation: .exactWords)
    }

    // Whole turns can mix alphabets and substitute words, so the single-letter
    // repair cannot align them. Reuse the unprompted acoustic reading only when
    // it retains the surrounding Russian speech and Qwen confirms it in Russian.
    private static func mixedCyrillicSpelling(original: String, heard: String, vocabulary: String) -> CyrillicSpellingRepair? {
        let source = words(original), candidate = words(heard)
        let distinct = source.filter(ParakeetRecognitionPolicy.hasDistinctCyrillicLetters)
        guard Set(distinct).count >= 2, similarLength(source, candidate),
              !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(heard),
              MeetingSpeechText.accepts(heard), TranscriptOrthography.literalRanges(in: original).isEmpty,
              preservesVocabulary(candidate: heard, original: original, vocabulary: vocabulary) else { return nil }

        let russianSource = source.filter(isCyrillic)
        let shared = russianSource.count - candidate.difference(from: russianSource).removals.count
        let otherSourceWords = source.filter { !isCyrillic($0) && !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters($0) }
        guard shared >= 5, shared * 5 >= russianSource.count * 2,
              otherSourceWords == candidate.filter({ !isCyrillic($0) }) else { return nil }

        var text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.last == ",", let ending = original.last, ".!?…".contains(ending) {
            text.removeLast()
            text.append(ending)
        }
        return CyrillicSpellingRepair(text: text, confirmedByRepetition: false, confirmation: .mixedTurn(original: original))
    }

    /// Use the independent audio decode as spelling evidence. Preserve every
    /// original separator and require agreement on all surrounding words.
    private static func letterSpelling(original: String, heard: String, vocabulary: String) -> CyrillicSpellingRepair? {
        let source = tokens(in: original), independent = tokens(in: heard)
        guard source.count == independent.count else { return nil }
        let changed = source.indices.filter { source[$0].key != independent[$0].key }
        guard changed.contains(where: { ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(source[$0].key) }) else { return nil }
        let protected = TranscriptOrthography.literalRanges(in: original)
            + TranscriptOrthography.glossaryRanges(in: original, vocabulary: vocabulary, range: NSRange(original.startIndex..., in: original))
        let attached = CharacterSet(charactersIn: "_/@\\-‐‑'’")
        let result = NSMutableString(string: original)
        var allRepeated = true
        for index in changed.reversed() {
            let token = source[index], target = independent[index]
            let range = NSRange(token.range, in: original)
            let isCommonWord = target.key.count >= 5 && TranscriptTerms.isCommonRussianWord(target.key)
            guard token.key.count == target.key.count,
                  isCommonWord || AbbreviationFamilies.isRussianFunctionWord(target.key),
                  !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  original[..<token.range.lowerBound].unicodeScalars.last.map(attached.contains) != true,
                  original[token.range.upperBound...].unicodeScalars.first.map(attached.contains) != true else { return nil }
            let differences = zip(token.key, target.key).enumerated().filter { $0.element.0 != $0.element.1 }
            let changesOnlyDistinctLetters = differences.allSatisfy {
                ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(String($0.element.0))
            }

            // A Russian-only decoder can transcribe other Slavic languages
            // phonetically. Bypass a multilingual reread only if the primary
            // heard a Russian-alphabet copy and a characteristic Russian ending.
            let repeated = isCommonWord && differences.count == 1 && [index - 1, index + 1].contains { neighbor in
                guard source.indices.contains(neighbor), independent[neighbor].key == target.key else { return false }
                let other = source[neighbor]
                let (damaged, russianCopy) = isCyrillic(token.key) ? (other, token) : (token, other)
                guard ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(damaged.key),
                      isCyrillic(russianCopy.key), withinOneEdit(russianCopy.key, target.key),
                      russianInflections.contains(where: { damaged.key.hasSuffix($0) && target.key.hasSuffix($0) }) else { return false }
                let between = source[min(index, neighbor)].range.upperBound..<source[max(index, neighbor)].range.lowerBound
                return original[between].allSatisfy { $0 == "," || $0.isWhitespace && !$0.isNewline }
            }
            if !changesOnlyDistinctLetters {
                // A second, nearly identical copy can itself have one ordinary
                // typo. Never replace a different, correctly spelled word.
                guard repeated, isCyrillic(token.key), !TranscriptTerms.isCommonRussianWord(token.key) else { return nil }
            }
            allRepeated = allRepeated && repeated
            for change in differences.reversed() {
                let start = original.index(token.range.lowerBound, offsetBy: change.offset)
                let letter = target.text[target.text.index(target.text.startIndex, offsetBy: change.offset)]
                result.replaceCharacters(in: NSRange(start...start, in: original),
                                         with: original[start].isUppercase ? letter.uppercased() : letter.lowercased())
            }
        }
        return CyrillicSpellingRepair(text: result as String, confirmedByRepetition: allRepeated, confirmation: .letters(changedWords: Set(changed)))
    }

    static func shouldRecheck(language: String?, duration: Double, original: String, alternative: String) -> Bool {
        guard language?.lowercased() == "russian", duration >= 2,
              MeetingSpeechText.accepts(alternative) else { return false }
        let first = words(original), second = words(alternative)
        return !first.isEmpty && first != second && similarLength(first, second)
    }

    /// Necessary evidence for the existing broad-retry acceptance paths, not
    /// permission to edit. Keep every possible local disagreement, even when
    /// the verifier differs elsewhere; the fresh decode still has to corroborate it.
    static func canRevise(original: String, corroboration: String, hypothesis: String,
                          vocabulary: String, dictionaryCorroboration: String? = nil) -> Bool {
        if RecognitionConsensus.hasSplitDisagreement(original: original, corroboration: corroboration, vocabulary: vocabulary) { return true }
        let evidence = Set([corroboration, hypothesis,
            dictionaryCorroboration ?? SpokenVocabulary(vocabulary).apply(to: corroboration)])
        for heard in evidence {
            // Fused names and initialisms can use right-only anchors. Check
            // each proposal alone: a candidate may contain just one of several
            // conflicting proposals in the independent output.
            let proposals = repairProposals(in: heard)
            for proposal in proposals {
                if applyRepairs(original: original, proposals: [proposal], matching: proposals,
                                vocabulary: vocabulary) != nil { return true }
            }
            if hasAnchoredDifference(original, heard) { return true }
        }
        return false
    }

    private static func hasAnchoredDifference(_ original: String, _ evidence: String) -> Bool {
        struct Anchor: Hashable { let left: String; let right: String }
        func intervals(_ text: String) -> [Anchor: Set<String>] {
            let words = tokens(in: text)
            guard words.count >= 2 else { return [:] }
            var result: [Anchor: Set<String>] = [:]
            for left in 0..<(words.count - 1) {
                // Consensus permits zero to four words between its anchors;
                // dictionary repairs permit at most four. This deliberately
                // ignores their stricter uniqueness/literal/meaning checks.
                for right in (left + 1)...min(words.count - 1, left + 5) {
                    let anchor = Anchor(left: words[left].key, right: words[right].key)
                    let interval = String(text[words[left].range.upperBound..<words[right].range.lowerBound])
                    result[anchor, default: []].insert(interval)
                }
            }
            return result
        }
        let source = intervals(original), heard = intervals(evidence)
        return source.contains { anchor, originals in
            guard let alternatives = heard[anchor] else { return false }
            return originals.contains { previous in alternatives.contains { $0 != previous } }
        }
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
                            vocabulary: String, usesCyrillicHints: Bool, dictionaryCorroboration: String? = nil,
                            rawCandidate: String? = nil) -> String? {
        guard MeetingSpeechText.accepts(candidate) else { return nil }
        let split = RecognitionConsensus.revisedSplitText(original: original, candidate: rawCandidate ?? candidate,
            corroboration: corroboration, vocabulary: vocabulary) ?? original
        let acoustic = localizedRepair(original: split, candidate: candidate,
                                       corroboration: corroboration, vocabulary: vocabulary) ?? split
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
        return RecognitionConsensus.revisedText(original: original, candidate: rawCandidate ?? candidate,
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
        let families = AbbreviationFamilies(vocabulary)
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
        func isStandalone(_ range: Range<String.Index>, in text: String) -> Bool {
            let attached = "_/@\\-‐‑'’"
            return text[..<range.lowerBound].last.map(attached.contains) != true
                && text[range.upperBound...].first.map(attached.contains) != true
        }
        var edits: [(Range<String.Index>, String)] = []
        guard retry.count >= 3 else { return nil }
        // The independently corroborated form can restore an ending or a
        // dropped letter. A separately documented abbreviation stays intact.
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
                    guard originalForm != replacement, hypothesis[heardRange] == replacement else { continue }
                    if !validForm(originalForm) {
                        guard let form = AbbreviationFamilies.parse(replacement, as: term),
                              AbbreviationFamilies.omitsNumericAcronymLetter(originalForm, from: form),
                              !families.isExplicit(originalForm), !families.hasKnownBase(originalForm),
                              !old.contains(where: inProtectedPhrase),
                              isStandalone(oldRange, in: original),
                              isStandalone(replacementRange, in: candidate),
                              isStandalone(heardRange, in: hypothesis) else { continue }
                    }
                    guard !allTerms.contains(where: { other in
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
                let numeric = RecognitionVocabulary.numericForms(for: matchingTerms[0]) != nil
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
                      !numeric || !old.allSatisfy({ TranscriptTerms.isCommonRussianWord(source[$0].key) }),
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

extension RussianRecognition {
    // Only whole, uninterrupted Latin phrases framed by Russian words can be
    // compared locally. Leave code, quotations, acronyms and glossary terms alone.
    private static let embeddedLatin = try! NSRegularExpression(pattern:
        #"(?i)(?<![\p{L}\p{N}_])([а-яё]+)\h+((?:\p{Latin}+(?:[-'’]\p{Latin}+)*\h+){3,}\p{Latin}+(?:[-'’]\p{Latin}+)*)\h+(?=([а-яё]+)(?![\p{L}\p{N}_]))"#)

    struct EmbeddedLatinRepair {
        fileprivate var original: String
        fileprivate var span: Range<String.Index>
        fileprivate enum Evidence {
            case phrase(left: String, right: String, heard: [String])
            case word(index: Int, heard: String)
        }
        fileprivate var evidence: Evidence

        func confirmedText(language: String?, reread: String) -> String? {
            guard language?.lowercased() == "russian" else { return nil }
            if case let .word(index, heard) = evidence {
                guard let word = singleRussianWord(in: reread, matching: tokens(in: original), at: index),
                      word.key == heard else { return nil }
                return original.replacingCharacters(in: span, with: word.text)
            }
            guard case let .phrase(left, right, heard) = evidence,
                  let phrase = anchoredRussianPhrase(in: reread, left: left, right: right) else { return nil }
            let candidate = tokens(in: phrase)
            guard candidate.count == heard.count else { return nil }

            var exactContentWords = Set<String>()
            for (word, evidence) in zip(candidate, heard) {
                if word.key == evidence {
                    if word.key.count >= 4 && TranscriptTerms.isCommonRussianWord(word.key) {
                        exactContentWords.insert(word.key)
                    }
                    continue
                }
                // A compound can have two phonetic spellings. Allow a single
                // vowel difference only on a hyphenated part, never in the
                // surrounding facts or in standalone verbs, numbers or names.
                let hyphens = "-‐‑"
                let isCompound = phrase[..<word.range.lowerBound].last.map(hyphens.contains) == true
                    || phrase[word.range.upperBound...].first.map(hyphens.contains) == true
                let vowels = "аеёиоуыэюя"
                guard isCompound, word.key.count >= 3, evidence.count >= 3,
                      !RecognitionConsensus.isNumberWord(word.key), !RecognitionConsensus.isNumberWord(evidence),
                      word.key.filter({ !vowels.contains($0) }) == evidence.filter({ !vowels.contains($0) }),
                      withinOneEdit(word.key, evidence) else { return nil }
            }
            guard exactContentWords.count >= 2 else { return nil }
            return original.replacingCharacters(in: span, with: phrase)
        }
    }

    static func embeddedLatinRepair(original: String, heard: String, vocabulary: String) -> EmbeddedLatinRepair? {
        guard original.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let full = NSRange(original.startIndex..., in: original)
        let matches = embeddedLatin.matches(in: original, range: full)
        if matches.isEmpty { return singleEmbeddedLatinRepair(original: original, heard: heard, vocabulary: vocabulary) }
        guard matches.count == 1, let match = matches.first,
              let span = Range(match.range(at: 2), in: original),
              let leftRange = Range(match.range(at: 1), in: original),
              let rightRange = Range(match.range(at: 3), in: original) else { return nil }
        let left = words(String(original[leftRange])).joined(), right = words(String(original[rightRange])).joined()
        let latin = original[span].split(whereSeparator: \.isWhitespace)
        guard (4...14).contains(latin.count), max(left.count, right.count) >= 4,
              words(original).filter(isCyrillic).count >= 4,
              !latin.contains(where: { word in
                  word.split(whereSeparator: { "'’-".contains($0) }).contains { $0.dropFirst().contains(where: \.isUppercase) }
              }),
              let phrase = anchoredRussianPhrase(in: heard, left: left, right: right) else { return nil }
        let protected = TranscriptOrthography.literalRanges(in: original)
            + TranscriptOrthography.glossaryRanges(in: original, vocabulary: vocabulary, range: full)
        guard !protected.contains(where: { NSIntersectionRange($0, match.range(at: 2)).length > 0 }) else { return nil }
        // An independent Russian ASR may render a hesitation as “э-э”.
        // Exclude only these isolated sounds, keeping particles and negation.
        let evidence = words(phrase).filter { !["э", "ээ", "эм", "м"].contains($0) }
        guard (4...24).contains(evidence.count) else { return nil }
        return EmbeddedLatinRepair(original: original, span: span, evidence: .phrase(left: left, right: right, heard: evidence))
    }

    struct FormattedLatinWord {
        fileprivate let original: String
        fileprivate let primaryWord: String
        fileprivate let index: Int
        fileprivate let vocabulary: String

        func proposal(heard: String) -> EmbeddedLatinRepair? {
            guard let word = singleRussianWord(in: heard, matching: tokens(in: original), at: index),
                  withinOneEdit(russianLetters(primaryWord), word.key) else { return nil }
            return singleEmbeddedLatinRepair(original: original, heard: heard, vocabulary: vocabulary, formattedIndex: index)
        }
    }

    /// The glossary formatter, rather than the recognizer, can introduce a
    /// Latin name. Compare the unformatted word with the actual clip before
    /// considering that spelling established.
    static func formattedLatinWord(primary: String, formatted: String, vocabulary: String) -> FormattedLatinWord? {
        guard primary != formatted, formatted.utf8.contains(where: { (65...90).contains($0) || (97...122).contains($0) }) else { return nil }
        let raw = tokens(in: primary), rendered = tokens(in: formatted)
        guard raw.count >= 3, raw.count == rendered.count else { return nil }
        let changes = raw.indices.filter { raw[$0].key != rendered[$0].key }
        guard changes.count == 1, let index = changes.first, index > 0, index + 1 < raw.count,
              raw[index].key.count >= 4, isCyrillic(russianLetters(raw[index].key)),
              rendered[index].key.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        let phrases = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n")).map(words)
        guard phrases.contains([rendered[index].key]) else { return nil }
        let protected = TranscriptOrthography.literalRanges(in: primary)
            + TranscriptOrthography.glossaryRanges(in: primary, vocabulary: vocabulary, range: NSRange(primary.startIndex..., in: primary))
        guard !protected.contains(where: { NSIntersectionRange($0, NSRange(raw[index].range, in: primary)).length > 0 }) else { return nil }
        return FormattedLatinWord(original: formatted, primaryWord: raw[index].key, index: index, vocabulary: vocabulary)
    }

    /// A single title-case Latin word can be a real name. Require the two
    /// audio reads to agree on the word and every Russian word around it.
    private static func singleEmbeddedLatinRepair(original: String, heard: String, vocabulary: String,
                                                 formattedIndex: Int? = nil) -> EmbeddedLatinRepair? {
        let source = tokens(in: original)
        guard formattedIndex != nil || (4...12).contains(source.count) else { return nil }
        let foreign = source.indices.filter { !isCyrillic(source[$0].key) }
        guard foreign.count == 1, let index = foreign.first, index > 0, index + 1 < source.count else { return nil }
        let token = source[index]
        let introduced = formattedIndex == index
        guard token.key.count >= 3, token.key.utf8.allSatisfy({ (97...122).contains($0) }),
              introduced || (token.text.dropFirst().allSatisfy(\.isLowercase) && !TechnologyVocabulary.isCuratedTerm(token.text)),
              original[source[index - 1].range.upperBound..<token.range.lowerBound].allSatisfy(\.isWhitespace),
              original[token.range.upperBound..<source[index + 1].range.lowerBound].allSatisfy(\.isWhitespace),
              let word = singleRussianWord(in: heard, matching: source, at: index),
              TranscriptTerms.isCommonRussianWord(word.key), !RecognitionConsensus.isNumberWord(word.key),
              !AbbreviationFamilies.isRussianFunctionWord(word.key), !TranscriptTerms.isKnownEntityForm(word.key),
              let romanized = word.key.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false),
              !withinOneEdit(romanized, token.key) else { return nil }
        let protected = TranscriptOrthography.literalRanges(in: original) + TranscriptOrthography.glossaryRanges(
            in: original, vocabulary: vocabulary, range: NSRange(original.startIndex..., in: original),
            minimumWordCount: introduced ? 2 : 1)
        let range = NSRange(token.range, in: original)
        guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
              !TechnologyVocabulary.hasPrecedingCompanyCue(in: original, before: range, protecting: protected) else { return nil }
        return EmbeddedLatinRepair(original: original, span: token.range, evidence: .word(index: index, heard: word.key))
    }

    private static func singleRussianWord(in reading: String, matching source: [Token], at index: Int) -> Token? {
        let checked = tokens(in: reading)
        guard checked.count == source.count, source.indices.allSatisfy({ $0 == index || checked[$0].key == source[$0].key }),
              checked[index].key.count >= 4, isCyrillic(checked[index].key), checked[index].text.dropFirst().allSatisfy(\.isLowercase),
              TranscriptOrthography.literalRanges(in: reading).isEmpty else { return nil }
        return checked[index]
    }

    private static func anchoredRussianPhrase(in text: String, left: String, right: String) -> String? {
        let reading = tokens(in: text)
        let starts = reading.indices.filter { reading[$0].key == left }
        let ends = reading.indices.filter { reading[$0].key == right }
        guard starts.count == 1, ends.count == 1, let start = starts.first, let end = ends.first,
              (4...28).contains(end - start - 1),
              reading[(start + 1)..<end].allSatisfy({ isCyrillic($0.key) }) else { return nil }
        let context = reading[start].range.upperBound..<reading[end].range.lowerBound
        guard text[context].allSatisfy({ $0.isLetter || $0 == " " || ",-‐‑".contains($0) }),
              !TranscriptOrthography.literalRanges(in: text).contains(where: {
                  NSIntersectionRange($0, NSRange(context, in: text)).length > 0
              }) else { return nil }
        return String(text[reading[start + 1].range.lowerBound..<reading[end - 1].range.upperBound])
    }
}
