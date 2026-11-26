import Foundation

/// Language-neutral vocal acknowledgments need nearby conversation context.
/// Known fillers can use a Russian spelling when a new audio decode is inconclusive.
enum BackchannelLanguage {
    private static let neutralVocalizations: Set<String> = ["ah", "uh", "huh", "uhhuh", "hmm", "hm", "mm", "mhm", "mmhmm", "uhum", "um"]
    private static let latinVocalizations = neutralVocalizations.union(["ajá"])
    private static let englishAffirmatives: Set<String> = ["yeah", "yep", "yes"]
    private static let englishOpenVowels: Set<String> = ["ah", "uh", "um"]
    private static let russianVocalizations: Set<String> = ["угу", "ага", "мгм", "хм", "мм", "м", "эм"]
    private static let fillerSpellings: [String: String] = [
        "ah": "а", "uh": "аааа", "um": "ааа", "huh": "а",
        "hmm": "хм", "hm": "хм", "mm": "мм", "mhm": "угу", "mmhmm": "угу",
        "uhum": "угу", "ajá": "ага",
        "uh huh": "угу", "uhhuh": "угу", "mm hmm": "угу",
        "yes": "да", "yeah": "да", "yep": "да", "da": "да", "ok": "окей", "okay": "окей",
        "sorry": "сорри",
    ]
    private static let russianFillers = Set(fillerSpellings.values).union(russianVocalizations)
    private static let shortSentenceWords: Set<String> = [
        "i", "you", "he", "she", "we", "they", "it", "am", "is", "are", "was", "were", "do", "does", "did",
        "can", "could", "will", "would", "shall", "should", "what", "who", "where", "when", "why", "how",
        "я", "ты", "он", "она", "мы", "вы", "они", "это", "как", "где", "когда", "куда", "кто", "что", "почему",
    ]
    private static let questionAuxiliaries: Set<String> = ["am", "is", "are", "was", "were", "do", "does", "did", "can", "could", "will", "would", "shall", "should"]
    private static let questionSubjects: Set<String> = ["i", "you", "he", "she", "we", "they", "it", "this", "that", "these", "those"]
    // Unlike shared words such as "мы" or "над", these common spellings
    // distinguish colloquial Russian from Ukrainian and Belarusian.
    private static let russianContextWords: Set<String> = [
        "вот", "давайте", "здесь", "очень", "потому", "сегодня", "сейчас",
        "спасибо", "тоже", "только", "уже", "чтобы", "это", "этот",
    ]
    private static let literalMarks = try! NSRegularExpression(pattern:
        #"[/\\`"«»“”‘~@]|(?<![A-Za-z])['’]|['’](?![A-Za-z])|(?<=[A-Za-z])\.(?=[A-Za-z])"#)
    private static let fillerWords = try! NSRegularExpression(pattern: #"\p{L}+"#)
    private static let latinSpeech = try! NSRegularExpression(pattern: #"\A[\P{L}\p{Latin}]*\p{Latin}[\P{L}\p{Latin}]*\z"#)
    private static let latinLetter = try! NSRegularExpression(pattern: #"\p{Latin}"#)
    private static let lexicalLiteralMarks = CharacterSet(charactersIn: "_+#$%=<>[]{}|‹›„")
    private static let latinLexicalWords = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:[’'][A-Za-z]+)*"#)
    private static let contractionStems: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "that", "there", "who", "what", "where", "when", "how", "let",
        "aren", "can", "couldn", "didn", "doesn", "don", "hadn", "hasn", "haven", "isn", "mustn", "shouldn", "wasn", "weren", "won", "wouldn",
    ]
    private static let contractionEndings: Set<String> = ["m", "s", "re", "ve", "d", "ll", "t"]
    private static let briefCyrillicReply = try! NSRegularExpression(pattern: #"^([А-ЯЁа-яё][а-яё]{1,2}) +[а-яё]{4,}[.!?…]*$"#)
    private static let lexicalWordLimit = 12
    // A diarized region fits in one 30-second model input. Longer lexical
    // routes apply to sentences, rather than labels and lists of product names.
    private static let sentenceMarkers = shortSentenceWords.union(["the", "this", "that", "these", "those", "please", "my", "your", "our", "let"])

    static func shouldRecheck(_ text: String, duration: Double) -> Bool {
        guard duration <= 3, !containsLiteralMarks(text), !isStandaloneLatinTerm(text),
              text.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil else { return false }
        let words = RussianRecognition.words(text)
        // Mixed filler chains need spelling edits that retain the Russian reply.
        if words.contains(where: russianFillers.contains) { return false }
        if fillerSpelling(words) != nil { return true }
        return (1...3).contains(words.count) && words.joined().unicodeScalars.allSatisfy {
            (0x61...0x7A).contains($0.value)
        }
    }

    static func shouldRecheckLexical(_ text: String, duration: Double, vocabulary: String = "") -> Bool {
        guard (0...30).contains(duration) else { return false }
        if duration <= 2, isBriefCyrillicSource(text, vocabulary: vocabulary) { return true }
        guard isLexicalSource(text, vocabulary: vocabulary) else { return false }
        // An apostrophe inside an English contraction belongs to one spoken word.
        let count = latinLexicalWords.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        if duration <= 6, count <= lexicalWordLimit { return true }
        return count >= 4 && RussianRecognition.words(text).contains(where: sentenceMarkers.contains)
    }

    /// A few Latin words may cover only a fraction of the recorded turn.
    /// An explicit term can constrain the final edit without blocking this check.
    static func shouldVerifySparseLatinTurn(_ text: String, duration: Double) -> Bool {
        guard (8...30).contains(duration), !containsLiteralMarks(text),
              text.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil,
              !isStandaloneLatinTerm(text) else { return false }
        let words = RussianRecognition.words(text)
        let count = latinLexicalWords.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        return count >= 4 && Double(count) <= duration
            && words.joined().utf8.allSatisfy { (97...122).contains($0) }
            && words.contains(where: sentenceMarkers.contains)
    }

    /// A glossary match accounts for the spelling of its own words. It does
    /// not corroborate an English clause that the decoder attached to them.
    static func unprotectedClauseWords(_ text: String, duration: Double, vocabulary: String) -> Set<String>? {
        guard (0.2...4).contains(duration), !vocabulary.isEmpty,
              isLatinSpeech(text), shouldRecheckLexical(text, duration: duration, vocabulary: "") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let words = latinLexicalWords.matches(in: text, range: range)
        guard (3...8).contains(words.count) else { return nil }
        let glossary = TranscriptOrthography.glossaryRanges(in: text, vocabulary: vocabulary, range: range)
        guard !glossary.isEmpty else { return nil }
        let free = words.compactMap { match -> String? in
            guard !glossary.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let span = Range(match.range, in: text) else { return nil }
            return text[span].lowercased()
        }
        guard free.count >= 2, !sentenceMarkers.isDisjoint(with: free) else { return nil }
        return Set(free)
    }

    static func corroboratedRussianTurn(original: String, language: String?, reread: String,
                                        corroboration: String, vocabulary: String) -> String? {
        guard language?.lowercased() == "russian",
              ![original, reread, corroboration].contains(where: containsLiteralMarks),
              let candidate = RecognitionConsensus.corroboratedRussianTurn(original: original,
                  candidate: reread, corroboration: corroboration),
              preservesLexicalVocabulary(candidate: candidate, original: original, vocabulary: vocabulary) else { return nil }
        return candidate
    }

    static func isIncompleteLatinReply(_ text: String, vocabulary: String) -> Bool {
        let words = RussianRecognition.words(text)
        let article = words.count == 1 && ["a", "an", "the"].contains(words[0])
        let unfinishedQuestion = words.count == 2 && questionAuxiliaries.contains(words[0])
            && questionSubjects.contains(words[1]) && text.last?.isLetter == true
        return (article || unfinishedQuestion) && isLexicalSource(text, vocabulary: vocabulary)
    }

    static func isBriefCyrillicSource(_ text: String, vocabulary: String) -> Bool {
        guard briefCyrillicReply.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        let words = RussianRecognition.words(text)
        return words.count == 2 && !TranscriptTerms.isCommonRussianWord(words[0])
            && !AbbreviationFamilies.isRussianFunctionWord(words[0]) && TranscriptTerms.isCommonRussianWord(words[1])
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    // Short turns can be decoded entirely in a neighboring Cyrillic language,
    // in accented Latin, or in both scripts. Only audio can resolve them.
    static func shouldVerifyShortScript(_ text: String, duration: Double, vocabulary: String) -> Bool {
        guard (0...6).contains(duration) else { return false }
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains)
        guard letters.contains(where: { !$0.isASCII }) else { return false }
        let latin = latinLetter.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        let distinctCyrillic = ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(text) && latin == 0
        guard distinctCyrillic || latin * 2 > letters.count || shortVocalizationBeforeRussianWord(text),
              !MeetingSpeechText.containsForeignLetters(text), !containsLiteralMarks(text),
              text.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil else { return false }
        let words = text.split(whereSeparator: { !$0.isLetter })
        return (2...lexicalWordLimit).contains(words.count)
            && (distinctCyrillic || words.filter({ word in word.unicodeScalars.allSatisfy { (0x400...0x52f).contains($0.value) } }).count <= 1)
            && !words.contains(where: { $0.dropFirst().contains(where: \.isUppercase) })
            && !words.dropFirst().contains(where: { $0.first?.isUppercase == true })
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    /// On short turns a multilingual primary can change the word boundaries
    /// or the entire script. Check these only against the same speaker's audio.
    static func shouldVerifyTimedClause(_ text: String, duration: Double, vocabulary: String) -> Bool {
        guard (0.3...2).contains(duration), !containsLiteralMarks(text),
              text.allSatisfy({ $0.isLetter || $0.isWhitespace || ",.!?…".contains($0) }),
              preservesLexicalVocabulary(candidate: "", original: text, vocabulary: vocabulary),
              russianSpelling(ofFiller: text) == nil else { return false }
        let tokens = text.split(whereSeparator: { !$0.isLetter })
        guard !tokens.isEmpty, tokens.count <= 5,
              !tokens.contains(where: { $0.dropFirst().contains(where: \.isUppercase) }),
              tokens.dropFirst().allSatisfy({ $0.first?.isLowercase == true }) else { return false }
        if tokens.count == 1 {
            return isLatinSpeech(text) && tokens[0].count >= 4 && !tokens[0].allSatisfy(\.isASCII)
        }
        return shouldRecheckLexical(text, duration: duration, vocabulary: vocabulary)
            || (shouldVerifyShortScript(text, duration: duration, vocabulary: vocabulary)
                && latinLetter.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)
    }

    struct TimedClause {
        let text: String
        fileprivate let source: Set<String>
        fileprivate let keys: [String]
        fileprivate let omittedOnset: Bool
        fileprivate let previous: [String]
        fileprivate let following: [String]

        func confirmed(in reading: String) -> Bool {
            let heard = RussianRecognition.words(reading)
            guard source.isDisjoint(with: heard.map({ $0.folding(options: .diacriticInsensitive, locale: nil) })) else { return false }
            let matches = heard.indices.filter { heard[$0...].starts(with: keys) }
            guard matches.count == 1, let i = matches.first else { return false }
            if i > 0, RecognitionConsensus.isSensitiveAtCut(heard[i - 1]),
               omittedOnset || previous.last != heard[i - 1] { return false }
            func sharesAnchor(_ expected: [String], _ nearby: ArraySlice<String>) -> Bool {
                let pairs = zip(nearby, nearby.dropFirst())
                return zip(expected, expected.dropFirst()).contains { a, b in
                    max(a.count, b.count) >= 4 && pairs.contains { $0 == a && $1 == b }
                }
            }
            return sharesAnchor(previous, heard[..<i].suffix(6))
                || sharesAnchor(following, heard.dropFirst(i + keys.count).prefix(6))
        }

        /// A short English clause can sound like one inflected Russian loanword
        /// in isolation. Require the same grammatical link on the left and a
        /// second, uninflected occurrence on the right in all three wide reads.
        func confirmsRepeatedInstrumental(verifier: String, primary: String) -> Bool {
            guard !omittedOnset, source.count == 2, keys.count == 1, let noun = keys.first,
                  noun.count >= 6, noun.hasSuffix("ом") || noun.hasSuffix("ем"),
                  previous.count >= 2, let preposition = previous.last,
                  ["с", "со", "над", "под", "перед", "между"].contains(preposition) else { return false }
            let lead = Array(previous.suffix(2))
            // Both lead words are outside the target and must be repeated
            // verbatim; a common word can also be a known name form.
            guard lead[0].count >= 3 else { return false }
            let stem = String(noun.dropLast(2))
            guard following.contains(stem) else { return false }
            let phrase = lead + [noun]
            return [verifier, primary].allSatisfy { reading in
                guard !BackchannelLanguage.containsLiteralMarks(reading) else { return false }
                let words = RussianRecognition.words(reading)
                let positions = words.indices.filter { words[$0...].starts(with: phrase) }
                guard positions.count == 1, let i = positions.first else { return false }
                return words.dropFirst(i + phrase.count).prefix(6).contains(stem)
            }
        }
    }

    static func timedClause(source: String, isolated: RecognitionAcousticResult,
                            wide: RecognitionAcousticResult, interval: Range<Double>) -> TimedClause? {
        let exact = RussianRecognition.words(isolated.text), heard = RussianRecognition.words(wide.text)
        guard (1...5).contains(exact.count), exact == isolated.words.flatMap({ RussianRecognition.words($0.text) }),
              exact.count == isolated.words.count, heard.count == wide.words.count,
              heard == wide.words.flatMap({ RussianRecognition.words($0.text) }),
              exact.allSatisfy({ $0.unicodeScalars.allSatisfy { (0x430...0x44f).contains($0.value) }
                  && !TranscriptTerms.isKnownEntityForm($0) }),
              isolated.text.dropFirst().allSatisfy({ !$0.isUppercase }) else { return nil }
        // The same words must start at the same times on narrow and wide
        // audio. A neighboring speaker's sentence alone proves nothing.
        let first = exact.indices.first { j in
            heard.indices.contains { i in
                heard[i] == exact[j] && abs(wide.words[i].start - interval.lowerBound - isolated.words[j].start) <= 0.16
            }
        }
        // Only nonlexical sounds may be omitted. A short name, pronoun or
        // negation can be the most important word in the utterance.
        let hesitations = ["э", "эм", "мм", "м", "хм", "эй"]
        guard let first, first == 0 || (first == 1 && hesitations.contains(exact[0]) && exact.count == 2 && exact[1].count >= 5)
        else { return nil }
        let keys = Array(exact[first...])
        // Both Russian reads can transliterate a genuine standalone foreign
        // name in a Russian sentence. Its spoken form corroborates the source.
        let original = RussianRecognition.words(source)
        if original.count == 1, keys.count == 1,
           let roman = keys[0].applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false),
           let latin = original[0].applyingTransform(.stripDiacritics, reverse: false),
           SpokenVocabulary.distance(roman, latin) <= 1 { return nil }
        let hits = heard.indices.filter { i in
            heard[i...].starts(with: keys) && keys.indices.allSatisfy { j in
                let time = wide.words[i + j].start
                return time >= interval.lowerBound - 0.12 && time < interval.upperBound
                    && abs(time - interval.lowerBound - isolated.words[first + j].start) <= 0.16
            }
        }
        guard hits.count == 1, let i = hits.first,
              first == 0 || i == 0 || !RecognitionConsensus.isSensitiveAtCut(heard[i - 1]),
              !wide.words.enumerated().contains(where: { index, word in
                  !(i..<(i + keys.count)).contains(index) && word.start >= interval.lowerBound + 0.12
                      && word.start < interval.upperBound - 0.12
              }) else { return nil }
        let text: String
        if first == 0 {
            let raw = isolated.text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = raw.prefix(1).uppercased() + String(raw.dropFirst()) + (raw.last?.isLetter == true ? "." : "")
        } else {
            text = "… " + wide.words[i].text.lowercased() + "."
        }
        let sourceWords = Set(RussianRecognition.words(source).compactMap { word -> String? in
            guard latinLetter.firstMatch(in: word, range: NSRange(word.startIndex..., in: word)) != nil else { return nil }
            return word.folding(options: .diacriticInsensitive, locale: nil)
        })
        return TimedClause(text: text, source: sourceWords, keys: keys, omittedOnset: first > 0,
            previous: Array(heard[..<i].suffix(6)), following: Array(heard.dropFirst(i + keys.count).prefix(6)))
    }

    private static func shortVocalizationBeforeRussianWord(_ text: String) -> Bool {
        let words = RussianRecognition.words(text)
        return words.count == 2 && latinVocalizations.contains(words[0]) && words[1].count >= 3
            && TranscriptTerms.isCommonRussianWord(words[1])
    }

    /// A Latin stem fused to Cyrillic letters, or a hesitation followed by a
    /// word in a neighboring language, can make a whole short turn ambiguous.
    static func shortMixedFragment(_ text: String, duration: Double, vocabulary: String) -> Bool {
        guard (0...4).contains(duration), text.utf8.contains(where: { (97...122).contains($0) }),
              text.contains(where: { !$0.isASCII }),
              text.allSatisfy({ $0.isLetter || $0.isWhitespace || ",.!?…".contains($0) }),
              RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary) else { return false }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".!?…")))
        let words = body.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        // A word can switch scripts twice mid-stem in a longer turn. A
        // foreign sentence with an ordinary loanword has no such corruption.
        if (2...5).contains(words.count),
           let last = words.last, last.allSatisfy(\.isLowercase),
           last.range(of: #"^\p{Latin}{2,}\p{Cyrillic}+\p{Latin}{2,}$"#, options: .regularExpression) != nil {
            return words.dropLast().enumerated().allSatisfy { index, token in
                token.allSatisfy { $0.isASCII && $0.isLetter }
                    && (index == 0 ? token.dropFirst().allSatisfy(\.isLowercase) : token.allSatisfy(\.isLowercase))
            }
        }
        if words.count == 2 {
            return latinVocalizations.contains(words[0].lowercased()) && words[1].count >= 3
                && words[1].allSatisfy(\.isLowercase)
                && words[1].unicodeScalars.allSatisfy { (0x400...0x52f).contains($0.value) }
                && ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(String(words[1]))
        }
        guard words.count == 1, let word = words.first, word == body else { return false }
        let stem = word.prefix(while: \.isASCII), suffix = word.dropFirst(stem.count)
        guard stem.count >= 2, stem.allSatisfy(\.isLetter), stem.dropFirst().allSatisfy(\.isLowercase),
              suffix.count >= 2, suffix.unicodeScalars.allSatisfy({ (0x430...0x44f).contains($0.value) || $0.value == 0x451 }),
              !TechnologyVocabulary.russianEndings.contains(String(suffix)), !TechnologyVocabulary.isCanonical(String(stem)),
              RussianRecognition.preservesVocabulary(candidate: "", original: String(stem), vocabulary: vocabulary) else { return false }
        return true
    }

    /// A multilingual recognizer retaining the foreign spelling is positive
    /// evidence, including when it separates a fused stem from its suffix.
    private static func confirmsMixedFragment(original: String, reread: String, language: String?) -> Bool {
        let source = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
        if confirmsCyrillicSource(original: original, reread: reread, language: language) { return true }
        guard !checked.isEmpty, let word = source.first else { return false }
        if source.joined() == checked.joined() { return true }
        if source.count >= 2, source.count == checked.count, source.dropLast() == checked.dropLast(),
           let tail = source.last, let heard = checked.last, isLatinSpeech(heard),
           let latin = tail.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false),
           let folded = heard.applyingTransform(.stripDiacritics, reverse: false),
           SpokenVocabulary.distance(latin, folded) <= 1 { return true }
        if source.count == 2, let last = source.last, checked == [last],
           ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(last) { return true }
        if source.count == 1 {
            let stem = String(word.prefix(while: \.isASCII))
            return !stem.isEmpty && checked.contains(stem)
        }
        return false
    }

    static func mixedFragmentReading(original: String, reread: String, language: String?,
                                     corroboration: String?) -> (alternative: String?, uncertain: Bool) {
        guard !confirmsMixedFragment(original: original, reread: reread, language: language),
              let corroboration else { return (nil, false) }
        if language?.lowercased() == "russian", !containsLiteralMarks(reread), !containsLiteralMarks(corroboration) {
            if let candidate = agreedRussianText(reread, corroboration: corroboration) { return (candidate, false) }
            // A short hesitation can be absent from one read. Keep it only
            // when the primary and the other read also heard that same sound.
            let source = RussianRecognition.words(original)
            if source.count == 2, let onset = leadingVocalization(source) {
                for (full, short) in [(reread, corroboration), (corroboration, reread)] {
                    let words = RussianRecognition.words(full), body = RussianRecognition.words(short)
                    guard body.count == 1, let word = body.first, TranscriptTerms.isCommonRussianWord(word),
                          let lead = leadingVocalization(words), lead.spelling == onset.spelling,
                          words.dropFirst(lead.count).elementsEqual(body),
                          full.unicodeScalars.filter(CharacterSet.letters.contains).allSatisfy({ (0x400...0x52f).contains($0.value) }) else { continue }
                    return (full, false)
                }
            }
        }
        return (nil, !reread.isEmpty || language?.lowercased() == "none")
    }

    static func canRestoreLanguageAnchor(_ segment: TranscriptSegment) -> Bool {
        // Older live drafts have no provenance. Lexical substitutions in
        // those builds were restricted to at most six seconds.
        segment.independentRecognitionLanguage ?? (segment.end - segment.start > 6)
    }

    /// A single corrupted word can mix the two scripts even when the rest of
    /// a short turn is entirely Russian. Inspect the primary before a glossary
    /// homophone can replace one of its intact Russian context words.
    static func mixedWordIndex(_ text: String, duration: Double, vocabulary: String) -> Int? {
        guard (0...4).contains(duration), text.utf8.contains(where: { (97...122).contains($0) }),
              text.allSatisfy({ $0.isLetter || $0.isWhitespace || ",.!?…".contains($0) }) else { return nil }
        let raw = text.split(whereSeparator: { !$0.isLetter })
        guard (2...5).contains(raw.count) else { return nil }
        let positions = raw.indices.filter { i in
            let word = raw[i]
            return word == word.lowercased() && word.utf8.contains(where: { (97...122).contains($0) })
                && word.unicodeScalars.filter { (0x430...0x44f).contains($0.value) || $0.value == 0x451 }.count >= 2
        }
        guard positions.count == 1, let damaged = positions.first else { return nil }
        let words = RussianRecognition.words(text)
        guard words.indices.allSatisfy({ i in
            i == damaged || (i == 0 && leadingVocalization([words[i]]) != nil)
                || ((i == 0 || raw[i].first?.isLowercase == true)
                    && (AbbreviationFamilies.isRussianFunctionWord(words[i]) || TranscriptTerms.isCommonRussianWord(words[i])))
        }), RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary) else { return nil }
        return damaged
    }

    static func restoredMixedWord(_ original: String, index: Int, reread: String, corroboration: String,
                                 isolatedCorroboration: String? = nil) -> String? {
        let source = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
        var heard = RussianRecognition.words(corroboration)
        let hasOnset = index > 0 && leadingVocalization(source) != nil
        if hasOnset, let onset = leadingVocalization(heard) { heard.removeFirst(onset.count) }
        let primary = Array(source.dropFirst(hasOnset ? 1 : 0)), position = index - (hasOnset ? 1 : 0)
        guard primary.count == heard.count, heard.indices.contains(position),
              primary.indices.allSatisfy({ $0 == position || primary[$0] == heard[$0] }) else { return nil }
        let word = heard[position], damaged = primary[position]
        if let isolatedCorroboration {
            let isolated = RussianRecognition.words(isolatedCorroboration)
            guard isolated.filter({ $0 == word }).count == 1,
                  (isolated.count == primary.count && isolated[position] == word)
                    || (position == 0 && isolated.first == word) || (position == primary.count - 1 && isolated.last == word) else { return nil }
        }
        let start = damaged.prefix(while: { !$0.isASCII }), end = String(damaged.reversed().prefix(while: { !$0.isASCII }).reversed())
        guard TranscriptTerms.isCommonRussianWord(word),
              (start.count >= 2 && word.hasPrefix(start)) || (end.count >= 2 && word.hasSuffix(end)),
              checked.filter({ $0 == word }).count == 1,
              (checked.count == primary.count && checked[position] == word)
                || (position == 0 && checked.first == word) || (position == primary.count - 1 && checked.last == word) else { return nil }
        let matches = fillerWords.matches(in: original, range: NSRange(original.startIndex..., in: original))
        guard matches.indices.contains(index), let range = Range(matches[index].range, in: original) else { return nil }
        if hasOnset, primary.count == 1 { return word + String(original[range.upperBound...]) }
        return original.replacingCharacters(in: range, with: word)
    }

    static func confirmsOriginalMixedWordContext(original: String, rendered: String, index: Int, corroboration: String) -> Bool {
        let words = RussianRecognition.words(original), displayed = RussianRecognition.words(rendered)
        let heard = RussianRecognition.words(corroboration)
        guard words != displayed, words.count == displayed.count, words.count == heard.count,
              words.indices.contains(index), words[index] == displayed[index] else { return false }
        return words.indices.allSatisfy { $0 == index || words[$0] == heard[$0] }
    }

    private static func isLexicalSource(_ text: String, vocabulary: String) -> Bool {
        guard !containsLiteralMarks(text), text.rangeOfCharacter(from: lexicalLiteralMarks) == nil,
              !isStandaloneLatinTerm(text) else { return false }
        let words = RussianRecognition.words(text)
        return !words.isEmpty
            && words.joined().unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) }
            && preservesLexicalVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    private static func preservesLexicalVocabulary(candidate: String, original: String, vocabulary: String) -> Bool {
        func joiningContractions(_ text: String) -> String {
            guard text.contains("'") || text.contains("’") else { return text }
            var joined = text
            let matches = latinLexicalWords.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: joined) else { continue }
                let parts = joined[range].split { $0 == "'" || $0 == "’" }
                guard parts.count == 2, parts[0].dropFirst().allSatisfy(\.isLowercase),
                      contractionStems.contains(parts[0].lowercased()), contractionEndings.contains(String(parts[1])) else { continue }
                // A modifier letter keeps the contraction together in the
                // glossary tokenizer while retaining distinct spellings.
                joined.replaceSubrange(range, with: parts.joined(separator: "ʼ"))
            }
            return joined
        }
        // In English sentences Parakeet writes the pronoun "it" in lowercase
        // or sentence case. Glossary formatting can subsequently turn it into
        // "IT". An acronym actually present in the primary keeps its protection.
        var glossary = vocabulary
        if vocabulary.contains("IT"), !original.contains("IT") {
            let tokens = latinLexicalWords.matches(in: original, range: NSRange(original.startIndex..., in: original))
                .compactMap { Range($0.range, in: original).map { String(original[$0]) } }
            if tokens.count >= 2, tokens.contains("it") || tokens.first == "It" {
                glossary = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
                    .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) != "IT" }.joined(separator: "\n")
            }
        }
        return RussianRecognition.preservesVocabulary(candidate: joiningContractions(candidate),
            original: joiningContractions(original), vocabulary: joiningContractions(glossary))
    }

    static func sourceForLanguageCheck(primary: String, formatted: String, duration: Double, vocabulary: String) -> String {
        guard primary != formatted, primary.caseInsensitiveCompare(formatted) == .orderedSame,
              shouldRecheckLexical(primary, duration: duration, vocabulary: vocabulary),
              !shouldRecheckLexical(formatted, duration: duration, vocabulary: vocabulary) else { return formatted }
        return primary
    }

    private static func isStandaloneLatinTerm(_ text: String) -> Bool {
        let words = text.split { !$0.isLetter }
        guard (1...4).contains(words.count),
              words.allSatisfy({ $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) } }) else { return false }
        let keys = words.map { $0.lowercased() }
        guard fillerSpelling(keys) == nil, !keys.contains(where: sentenceMarkers.contains) else { return false }
        if keys == ["proof", "of", "concept"] { return true }
        guard words.allSatisfy({ $0.first?.isUppercase == true }) else { return false }
        return words.contains { $0.dropFirst().contains(where: \.isUppercase) }
    }

    /// The caller supplies unprompted multilingual recognition of the same audio.
    /// The independent Russian recognizer must corroborate every word.
    static func lexicalAlternative(original: String, russian: String, corroboration: String?, vocabulary: String = "") -> String? {
        guard let corroboration else { return nil }
        let words = RussianRecognition.words(russian)
        if isBriefCyrillicSource(original, vocabulary: vocabulary) {
            guard words.count == 2, words == RussianRecognition.words(corroboration),
                  words[1] == RussianRecognition.words(original)[1], AbbreviationFamilies.isRussianFunctionWord(words[0]),
                  let match = briefCyrillicReply.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)),
                  let range = Range(match.range(at: 1), in: original) else { return nil }
            let replacement = original.first?.isUppercase == true ? words[0].capitalized : words[0]
            return original.replacingCharacters(in: range, with: replacement)
        }
        guard isLexicalSource(original, vocabulary: vocabulary) else { return nil }
        if let agreed = agreedRussianText(russian, corroboration: corroboration) { return agreed }
        // On a brief turn the models can hear the same sounds and place one
        // internal word boundary differently. Require identical letters and
        // shared words on both sides of the boundary.
        let heard = RussianRecognition.words(corroboration)
        let letters = words.joined()
        guard words.count >= 3, heard.count >= 3, abs(words.count - heard.count) == 1,
              letters == heard.joined(),
              letters.unicodeScalars.allSatisfy({ (0x430...0x44f).contains($0.value) }) else { return nil }
        let prefix = zip(words, heard).prefix { $0 == $1 }.count
        let suffix = zip(words.reversed(), heard.reversed()).prefix { $0 == $1 }.count
        guard prefix > 0, suffix > 0, prefix + suffix + 1 == min(words.count, heard.count) else { return nil }
        return russian.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func agreedRussianText(_ russian: String, corroboration: String?) -> String? {
        let words = RussianRecognition.words(russian)
        guard let corroboration, !words.isEmpty,
              words.joined().unicodeScalars.allSatisfy({ (0x0430...0x044F).contains($0.value) }),
              words == RussianRecognition.words(corroboration) else { return nil }
        return russian.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A padded multilingual read may compress a repeated particle. The
    /// isolated acoustic read must retain the primary's exact repeat count
    /// and agree with the multilingual read on every word after it.
    static func repeatedOnsetAlternative(original: String, padded: String, language: String?,
                                         isolated: String, acoustic: String) -> String? {
        guard language?.lowercased() == "russian",
              latinSpeech.firstMatch(in: original, range: NSRange(original.startIndex..., in: original)) != nil,
              !isolated.isEmpty,
              latinLetter.firstMatch(in: isolated, range: NSRange(isolated.startIndex..., in: isolated)) == nil,
              [padded, acoustic].allSatisfy({ text in
                  !containsLiteralMarks(text) && !text.dropFirst().contains(where: \.isUppercase)
                      && text.allSatisfy { $0.isLetter || $0.isWhitespace || ",.!?…-‐‑".contains($0) }
              }) else { return nil }
        let source = RussianRecognition.words(original), checked = RussianRecognition.words(padded)
        let heard = RussianRecognition.words(acoustic)
        guard let onset = checked.first, onset == heard.first, onset.count <= 3,
              AbbreviationFamilies.isRussianFunctionWord(onset), let foreignOnset = source.first,
              foreignOnset.count <= 3, source.count == heard.count else { return nil }
        let sourceRepeats = source.prefix { $0 == foreignOnset }.count
        let heardRepeats = heard.prefix { $0 == onset }.count
        let checkedRepeats = checked.prefix { $0 == onset }.count
        let tail = checked.dropFirst(checkedRepeats)
        guard sourceRepeats == heardRepeats, checkedRepeats >= 2, heardRepeats > checkedRepeats,
              tail.contains(where: { $0.count >= 4 && TranscriptTerms.isCommonRussianWord($0) }),
              tail.allSatisfy(TranscriptTerms.isCommonRussianWord),
              tail.elementsEqual(heard.dropFirst(heardRepeats)) else { return nil }
        // A translation shares meaning, but does not preserve the sound of
        // each source word. Fold Latin diacritics and a palatal glide before
        // e, then require exact agreement, including the repeated particle.
        func latinKey(_ word: String) -> String? {
            guard let latin = word.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(StringTransform("Latin-ASCII"), reverse: false),
                  latin.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
            return latin.replacingOccurrences(of: #"(?<=[b-df-hj-np-tv-z])[ij](?=e)"#, with: "",
                options: .regularExpression)
        }
        for (originalWord, russianWord) in zip(source.dropFirst(sourceRepeats - 1), heard.dropFirst(heardRepeats - 1)) {
            guard let key = latinKey(originalWord), key == latinKey(russianWord) else { return nil }
        }
        // A conflicting Cyrillic read on the core is also evidence. Only a
        // third, unrelated script can abstain without supporting either text.
        let coreWords = RussianRecognition.words(isolated)
        if coreWords.contains(where: { word in word.unicodeScalars.contains { (0x400...0x52f).contains($0.value) } }) {
            guard coreWords.prefix(while: { $0 == onset }).count >= 2,
                  coreWords.drop(while: { $0 == onset }).elementsEqual(tail) else { return nil }
        } else if !MeetingSpeechText.containsForeignLetters(isolated) {
            return nil
        }
        return acoustic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // A second multilingual reading in the source language is positive
    // evidence for an actual switch. The Russian-only model cannot veto it.
    static func confirmsCyrillicSource(original: String, reread: String, language: String?) -> Bool {
        guard ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(original),
              ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(reread) else { return false }
        let source = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
        if source == checked { return true }
        return ["ukrainian", "belarusian"].contains(language?.lowercased() ?? "")
            && source.contains { $0.count >= 3 && checked.contains($0) }
    }

    static func corroboratedScriptReread(_ russian: String, corroboration: String?) -> String? {
        let words = RussianRecognition.words(russian)
        guard words.contains(where: { TranscriptTerms.isCommonRussianWord($0) || russianFillers.contains($0) }) else { return nil }
        return agreedRussianText(russian, corroboration: corroboration)
    }

    /// For a compact mixed-script source, the multilingual read is unprompted.
    /// Disagreements about a boundary never authorize changes inside a clause.
    static func mixedRussianAlternative(original: String, language: String?, reread: String, corroboration: String?) -> String? {
        guard let corroboration else { return nil }
        if shortVocalizationBeforeRussianWord(original), !containsLiteralMarks(corroboration) {
            let source = RussianRecognition.words(original), heard = RussianRecognition.words(corroboration)
            if let first = leadingVocalization(source), let onset = leadingVocalization(heard), first.spelling == onset.spelling,
               heard.dropFirst(onset.count).elementsEqual(source.dropFirst(first.count)) {
                return corroboration
            }
        }
        if let fillers = mixedFillerAlternative(original: original, reread: reread, heard: corroboration) { return fillers }
        guard language?.lowercased() == "russian", !containsLiteralMarks(reread), !containsLiteralMarks(corroboration) else { return nil }
        if let full = agreedRussianText(reread, corroboration: corroboration) { return full }
        if let repair = RussianRecognition.shortCyrillicSpelling(original: original, reread: reread, heard: corroboration) { return repair }
        let checked = RussianRecognition.words(reread), source = RussianRecognition.words(original)
        let heard = RussianRecognition.words(corroboration)
        guard !checked.isEmpty, checked.allSatisfy({ word in word.unicodeScalars.allSatisfy { (0x430...0x44f).contains($0.value) } }) else { return nil }
        // Strip a hesitation from the acoustic comparison only when the
        // primary heard the same onset. Keep agreed lexical acknowledgments.
        var primary = source, body = heard
        if let onset = leadingVocalization(source), let acousticOnset = leadingVocalization(heard),
           onset.spelling == acousticOnset.spelling {
            primary.removeFirst(onset.count)
            body.removeFirst(acousticOnset.count)
            if body == checked { return onset.spelling == "а" ? reread : corroboration }
        }
        if body.starts(with: checked), body.count == checked.count + 1, checked.count >= 2,
           let last = body.last, last.count <= 3,
           AbbreviationFamilies.isRussianFunctionWord(last) || corroboration.hasSuffix("…") || corroboration.hasSuffix("...") {
            // A conjunction on the cut has no audible continuation here.
            let joined = checked.last.map { ["и", "а", "но", "или"].contains($0) } == true ? checked.count - 1 : checked.count
            let prefix = checked.prefix(joined)
            guard prefix.count >= 2, prefix.contains(where: { $0.count >= 4 && TranscriptTerms.isCommonRussianWord($0) }) else { return nil }
            let text = reread.trimmingCharacters(in: .whitespacesAndNewlines)
            let matches = fillerWords.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard let end = matches.prefix(joined).last.flatMap({ Range($0.range, in: text)?.upperBound }) else { return nil }
            return String(text[..<end]) + "…"
        }
        // The primary can spell one word in Cyrillic and its neighbor in
        // Latin. Only change script when every word retains its pronunciation
        // and the acoustic model confirms each changed position.
        guard (2...4).contains(checked.count), primary.count == checked.count, body.count >= checked.count else { return nil }
        var intact = false, respelled = false
        for index in checked.indices {
            if primary[index] == checked[index] { intact = true; continue }
            guard AbbreviationFamilies.isRussianFunctionWord(checked[index]), primary[index].utf8.allSatisfy({ (97...122).contains($0) }),
                  body[index] == checked[index],
                  checked[index].applyingTransform(.toLatin, reverse: false) == primary[index] else { return nil }
            respelled = true
        }
        return intact && respelled ? reread : nil
    }

    private static func leadingVocalization(_ words: [String]) -> (spelling: String, count: Int)? {
        guard let first = words.first else { return nil }
        let pair = words.prefix(2).joined(separator: " ")
        if let spelling = fillerSpellings[pair], words.count >= 2, russianVocalizations.contains(spelling) { return (spelling, 2) }
        if englishOpenVowels.contains(first) || isOpenVowel(first) {
            return ("а", words.count >= 2 && isOpenVowel(first) && isOpenVowel(words[1]) ? 2 : 1)
        }
        let spelling = fillerSpellings[first] ?? first
        return russianVocalizations.contains(spelling) ? (spelling, 1) : nil
    }

    private static func mixedFillerAlternative(original: String, reread: String, heard: String) -> String? {
        guard let confirmed = fillerEvidence(reread), confirmed == fillerEvidence(heard) else { return nil }
        let expected = confirmed.components(separatedBy: ", ")
        guard expected.count >= 3 else { return nil }
        var source = RussianRecognition.words(original)
        let unknown = source.indices.filter { fillerSpelling([source[$0]]) == nil }
        guard unknown.count == 1, let index = unknown.first, source[index].count <= 3,
              latinLetter.numberOfMatches(in: source[index], range: NSRange(source[index].startIndex..., in: source[index])) == source[index].count else { return nil }
        for spelling in Set(expected) {
            source[index] = spelling
            if fillerSpelling(source) == confirmed {
                let native = heard.replacingOccurrences(of: #"(?i)(о)['’](кей)"#, with: "$1$2", options: .regularExpression)
                guard latinLetter.firstMatch(in: native, range: NSRange(native.startIndex..., in: native)) == nil else { return nil }
                return native.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    /// The Russian-only reread has no text prompt and cannot supply words on
    /// its own. When its ending conflicts with the other acoustic model, keep
    /// only a corroborated opening and mark the missing audio explicitly.
    static func russianRereadAlternative(original: String, russian: String, corroboration: String, vocabulary: String) -> String? {
        let recognized = RussianRecognition.words(russian)
        // A Russian-forced spelling of an English term can agree with a
        // monolingual recognizer on transliteration alone.
        guard recognized.contains(where: { TranscriptTerms.isCommonRussianWord($0) || russianFillers.contains($0) }) else { return nil }
        if let full = lexicalAlternative(original: original, russian: russian, corroboration: corroboration, vocabulary: vocabulary) {
            return full
        }
        guard isLexicalSource(original, vocabulary: vocabulary), RussianRecognition.words(original).count >= 2 else { return nil }
        let heard = RussianRecognition.words(corroboration)
        let agreed = zip(recognized, heard).prefix(while: { $0 == $1 }).map(\.0)
        guard agreed.allSatisfy({ word in word.unicodeScalars.allSatisfy { (0x430...0x44f).contains($0.value) } }),
              (agreed.count == 1 && ["да", "нет"].contains(agreed[0]))
                || (agreed.count >= 2 && agreed.contains { $0.count >= 4 && TranscriptTerms.isCommonRussianWord($0) }) else { return nil }
        let trimmed = russian.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = fillerWords.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard let last = tokens.prefix(agreed.count).last, let range = Range(last.range, in: trimmed),
              !containsLiteralMarks(trimmed) else { return nil }
        return String(trimmed[..<range.upperBound]) + "…"
    }

    /// Missing evidence from either recognizer cannot establish an empty turn.
    static func hasNoSpeechEvidence(language: String?, text: String, corroboration: String?) -> Bool {
        guard language?.lowercased() == "none", let corroboration else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && corroboration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isLatinSpeech(_ text: String) -> Bool {
        latinSpeech.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    enum IsolatedLatinReading: Equatable {
        case source, foreign(String), russian(String), disputed, unconfirmed
    }

    static func needsIsolatedLanguageRead(latin: Bool, paddedConfirmsSource: Bool, isolatedAcoustic: String?) -> Bool {
        if latin { return !paddedConfirmsSource || isolatedAcoustic != nil }
        return ParakeetRecognitionPolicy.hasRussianTextEvidence(isolatedAcoustic ?? "")
    }

    /// Both readings refer to the diarized turn, without the surrounding voices.
    static func isolatedLatinReading(original: String, reread: String, language: String?,
                                    corroboration: String?, vocabulary: String) -> IsolatedLatinReading? {
        guard isLatinSpeech(original), !containsLiteralMarks(original), !isStandaloneLatinTerm(original),
              preservesLexicalVocabulary(candidate: "", original: original, vocabulary: vocabulary),
              original.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil else { return nil }
        if confirmsLatinSource(original: original, reread: reread) { return .source }
        // Two independent decoders may split a foreign compound that the
        // primary joined, with a doubled or omitted letter at that boundary.
        if let detected = language?.lowercased(), !["", "none", "russian", "unknown"].contains(detected),
           let corroboration, isLatinSpeech(reread), isLatinSpeech(corroboration),
           [reread, corroboration].allSatisfy({ $0.allSatisfy { $0.isLetter || $0.isWhitespace || ".,!?…".contains($0) } }) {
            let source = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
            let compact = source.joined(), expanded = checked.joined()
            if source.count == 1, checked.count == 2, checked.allSatisfy({ $0.count >= 2 }),
               checked == RussianRecognition.words(corroboration), compact.count >= 5,
               !reread.dropFirst().contains(where: \.isUppercase),
               (compact == expanded ||
                (Set(checked[0].suffix(2)).count == 1 && compact == String(checked[0].dropLast()) + checked[1]) ||
                (Set(checked[1].prefix(2)).count == 1 && compact == checked[0] + String(checked[1].dropFirst()))) {
                return .foreign(reread.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        // A padded decoder may agree with the primary even when its isolated
        // read switches script. Keep the source pending a timed contextual
        // check; neither this disagreement nor the Russian ASR supplies a word.
        if let detected = language?.lowercased(), !["", "russian", "english"].contains(detected),
           (detected == "none" && reread.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (reread.unicodeScalars.contains(where: CharacterSet.letters.contains) && !isLatinSpeech(reread)
                && Set(RussianRecognition.words(original)).isDisjoint(with: RussianRecognition.words(reread))),
           let corroboration, ParakeetRecognitionPolicy.hasRussianTextEvidence(corroboration),
           RussianRecognition.words(corroboration).contains(where: { word in
               word.count >= 2 && word.unicodeScalars.allSatisfy { (0x430...0x44f).contains($0.value) }
           }) { return .unconfirmed }
        guard language?.lowercased() == "russian", let corroboration,
              ParakeetRecognitionPolicy.hasRussianTextEvidence(reread),
              ParakeetRecognitionPolicy.hasRussianTextEvidence(corroboration) else { return nil }
        if let candidate = lexicalAlternative(original: original, russian: reread, corroboration: corroboration, vocabulary: vocabulary)
            ?? agreedRussianText(reread, corroboration: corroboration),
           preservesLexicalVocabulary(candidate: candidate, original: original, vocabulary: vocabulary) {
            return .russian(candidate)
        }
        return .disputed
    }

    /// When all three decoders hear the same foreign first word, focus the
    /// primary on the disputed ending. Keep half of the agreed word as a
    /// phonetic lead-in, leaving every sample of the second word intact.
    static func foreignEndingStart(original: String, reread: String, padded: String, language: String?,
                                   acoustic: RecognitionAcousticResult, sampleCount: Int, vocabulary: String) -> Int? {
        guard language?.lowercased() == "english", shouldRecheckLexical(original, duration: Double(sampleCount) / 16000,
                  vocabulary: vocabulary), sampleCount <= 2 * 16000,
              [original, reread, acoustic.text].allSatisfy({ isLatinSpeech($0) && !containsLiteralMarks($0)
                  && $0.allSatisfy({ $0.isLetter || $0.isWhitespace || ".,!?…".contains($0) }) }),
              confirmsLatinSource(original: reread, reread: padded) else { return nil }
        let primary = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
        let heard = acoustic.words.map { $0.text.lowercased() }
        guard primary.count == 2, checked.count == 2, heard.count == 2, heard == RussianRecognition.words(acoustic.text),
              primary[0].count >= 4, primary[0] == checked[0], checked[0] == heard[0],
              (2...5).contains(checked[1].count), [primary[1], heard[1]].allSatisfy({ (2...5).contains($0.count) }),
              primary[1] != checked[1], !reread.dropFirst().contains(where: \.isUppercase),
              let first = acoustic.words.first, let last = acoustic.words.last,
              first.start.isFinite, first.end.isFinite, last.start.isFinite, last.end.isFinite,
              first.start >= 0, first.end - first.start >= 0.25, first.end <= last.start,
              last.end > last.start, last.end <= Double(sampleCount) / 16000 + 0.02 else { return nil }
        return Int(((first.start + first.end) / 2 * 16_000).rounded())
    }

    /// Independent agreement preserves foreign Latin speech regardless of its
    /// language label. Punctuation and case do not change the spoken words.
    static func confirmsLatinSource(original: String, reread: String) -> Bool {
        guard isLatinSpeech(original), isLatinSpeech(reread) else { return false }
        let words = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
        guard !words.isEmpty else { return false }
        if words == checked { return true }
        // On a borrowed name or a short foreign quote the multilingual
        // decoder can omit written accents while hearing every word.
        if words.count == checked.count && zip(words, checked).allSatisfy({
            $0.compare($1, options: .diacriticInsensitive) == .orderedSame
        }) { return true }
        // Two decoders can clearly hear the same foreign sentence while
        // disagreeing about an article or contraction. A short homophone
        // still requires exact agreement.
        let longer = max(words.count, checked.count)
        guard longer >= 7, abs(words.count - checked.count) <= 2 else { return false }
        let removed = checked.difference(from: words).removals.count
        let shared = words.count - removed
        return longer - shared <= 2 && shared * 5 >= longer * 4
    }

    /// Three decoders may use different orthographies for the same sequence
    /// of sounds. Compare every acknowledgment, including its multiplicity,
    /// before treating a short turn as independently confirmed.
    static func confirmsFillerSequence(original: String, reread: String, corroboration: String?) -> Bool {
        guard let corroboration, let source = russianSpelling(ofFiller: original) else { return false }
        return source == fillerEvidence(reread) && source == fillerEvidence(corroboration)
    }

    static func preservesFillerSequenceLength(originalSpelling: String, candidate: String) -> Bool {
        let count = originalSpelling.components(separatedBy: ", ").count
        guard let spelling = fillerEvidence(candidate) else { return count == 1 }
        return spelling.components(separatedBy: ", ").count == count
    }

    private static func fillerEvidence(_ text: String) -> String? {
        let input = text.lowercased().replacingOccurrences(of: #"о['’]кей"#, with: "окей", options: .regularExpression)
        guard !containsLiteralMarks(input) else { return nil }
        let words = RussianRecognition.words(input).map { ["okei", "okey"].contains($0) ? "okay" : $0 }
        return fillerSpelling(words)
    }

    /// A short lead-in can stabilize decoding without cutting or changing speech.
    static func retryAudio(_ samples: [Float]) -> [Float] {
        Array(repeating: 0, count: 2_000) + samples
    }

    private static func isAmbiguous(_ words: [String]) -> Bool {
        words.contains(where: latinVocalizations.contains) && words.allSatisfy {
            latinVocalizations.contains($0) || englishAffirmatives.contains($0)
        }
    }

    static func acceptsAlternative(_ text: String, allowingAffirmative: Bool = false, allowingOpenVowels: Bool = false) -> Bool {
        let words = RussianRecognition.words(text)
        if allowingOpenVowels, !words.isEmpty, words.allSatisfy(isOpenVowel) { return true }
        guard (1...3).contains(words.count) else { return false }
        return words.contains(where: russianVocalizations.contains) && words.allSatisfy {
            russianVocalizations.contains($0) || (allowingAffirmative && $0 == "да")
        }
    }

    private static let alternativeParticles: Set<String> = ["я", "ну", "а", "и"]

    /// A vocalization can be verified by Qwen alone. A lexical reply needs
    /// the same one to three substantive words in the independent reading.
    static func canVerifyAlternative(original: String, corroboration: String?) -> Bool {
        if isVocalization(original) { return true }
        let independent = RussianRecognition.words(corroboration ?? "").filter { !alternativeParticles.contains($0) }
        return (1...3).contains(independent.count)
    }

    /// A forced language decode may translate real English. For lexical replies,
    /// require the independent acoustic recognizer to hear the same Russian words.
    /// A vocal acknowledgment may include a brief affirmative in either decode.
    static func alternative(original: String, russian: String, corroboration: String?, vocabulary: String = "") -> String? {
        let originalWords = RussianRecognition.words(original)
        if isAmbiguous(originalWords) {
            let hasAffirmative = originalWords.contains(where: englishAffirmatives.contains)
            let allowsOpenVowels = originalWords.allSatisfy(englishOpenVowels.contains)
            let candidate = [russian, corroboration].compactMap { $0 }.first {
                acceptsAlternative($0, allowingAffirmative: hasAffirmative, allowingOpenVowels: allowsOpenVowels)
            }
            if let candidate {
                return RussianRecognition.preservesVocabulary(candidate: candidate, original: original, vocabulary: vocabulary) ? candidate : nil
            }
            if !hasAffirmative { return nil }
        }
        let words = RussianRecognition.words(russian)
        guard (1...3).contains(words.count), words.joined().unicodeScalars.allSatisfy({ (0x0400...0x052F).contains($0.value) }),
              let corroboration,
              RussianRecognition.preservesVocabulary(candidate: russian, original: original, vocabulary: vocabulary) else { return nil }
        let substantive = words.filter { !alternativeParticles.contains($0) }
        let independent = RussianRecognition.words(corroboration).filter { !alternativeParticles.contains($0) }
        return !substantive.isEmpty && substantive == independent ? russian : nil
    }

    /// Contextual rereads and restored checkpoints retain segment IDs. Their
    /// revised words cannot be the source of an earlier language alternative.
    static func resolve(_ segments: [TranscriptSegment], evidence: BatchTranscriptionCheckpoint.FirstPass,
                        preceding: [TranscriptSegment], vocabulary: String) -> [TranscriptSegment] {
        let pending = Set(evidence.backchannels.keys).union(evidence.lexicalBackchannels.keys).union(evidence.uncertainShortLanguage)
        if pending.isEmpty { return resolve(segments, alternatives: [:], preceding: preceding, vocabulary: vocabulary) }
        let original = Dictionary(evidence.segments.lazy.filter { pending.contains($0.id) }.map { ($0.id, $0.text) },
                                  uniquingKeysWith: { first, _ in first })
        let stale = Set(segments.compactMap { pending.contains($0.id) && original[$0.id] != $0.text ? $0.id : nil })
        var current = segments
        for i in current.indices where stale.contains(current[i].id) { current[i].independentRecognitionLanguage = false }
        return resolve(current, alternatives: evidence.backchannels.filter { !stale.contains($0.key) },
            lexicalAlternatives: evidence.lexicalBackchannels.filter { !stale.contains($0.key) },
            uncertain: evidence.uncertainShortLanguage.subtracting(stale), preceding: preceding, vocabulary: vocabulary)
    }

    static func resolve(_ segments: [TranscriptSegment], alternatives: [UUID: String], lexicalAlternatives: [UUID: String] = [:],
                        uncertain: Set<UUID> = [], preceding: [TranscriptSegment], vocabulary: String = "") -> [TranscriptSegment] {
        var verifiedLexical: [UUID: String] = [:]
        var unconfirmed: Set<UUID> = []
        for segment in segments {
            let candidate = lexicalAlternatives[segment.id]
            let isUncertain = uncertain.contains(segment.id)
            if (candidate != nil || isUncertain),
               shortMixedFragment(segment.text, duration: segment.end - segment.start, vocabulary: vocabulary) {
                verifiedLexical[segment.id] = candidate
                if isUncertain { unconfirmed.insert(segment.id) }
                continue
            }
            guard candidate != nil || isUncertain else { continue }
            let duration = segment.end - segment.start
            let scriptCheck = shouldVerifyShortScript(segment.text, duration: duration, vocabulary: vocabulary)
            guard shouldRecheckLexical(segment.text, duration: duration, vocabulary: vocabulary)
                    || (RussianRecognition.isCyrillicSpeech(segment.text)
                        && (candidate != nil || RussianRecognition.words(segment.text).count == 1))
                    || (scriptCheck && (candidate != nil || isLatinSpeech(segment.text)))
                    || (candidate != nil && mixedWordIndex(segment.text, duration: duration, vocabulary: vocabulary) != nil)
            else { continue }
            verifiedLexical[segment.id] = candidate
            if isUncertain { unconfirmed.insert(segment.id) }
        }
        var replacements: [UUID: String] = [:]
        for segment in segments {
            let audio = shouldRecheck(segment.text, duration: segment.end - segment.start) ? alternatives[segment.id] : nil
            let fallback = localizedFiller(segment.text) ?? (unconfirmed.contains(segment.id) ? "Неразборчиво" : nil)
            if let replacement = verifiedLexical[segment.id] ?? audio ?? fallback,
               preservesLexicalVocabulary(candidate: replacement, original: segment.text, vocabulary: vocabulary) {
                replacements[segment.id] = replacement
            }
        }
        guard !replacements.isEmpty else { return segments }
        let anchors = (preceding + segments).compactMap { anchor -> (segment: TranscriptSegment, language: ConversationLanguage)? in
            // A disputed reading, proposed correction, or quote cannot
            // establish the language used to resolve neighboring turns.
            guard anchor.independentRecognitionLanguage != false,
                  verifiedLexical[anchor.id] == nil, !unconfirmed.contains(anchor.id) else { return nil }
            let spoken = NSMutableString(string: anchor.text)
            for range in TranscriptOrthography.literalRanges(in: anchor.text).reversed() {
                spoken.replaceCharacters(in: range, with: " ")
            }
            let text = spoken as String
            let words = RussianRecognition.words(text)
            let isShortSentence = (2...3).contains(words.count) && words.contains(where: shortSentenceWords.contains)
                && !containsLiteralMarks(text)
            guard words.count >= 4 || isShortSentence, fillerSpelling(words) == nil, !isStandaloneLatinTerm(text),
                  !words.allSatisfy({ russianFillers.contains($0) || isOpenVowel($0) }),
                  let language = conversationLanguage(text, words: words) else { return nil }
            // In a run of acknowledgments, one stray syllable does not establish
            // a language switch. Nor does an unfinished subject/auxiliary pair.
            let nonFillers = words.filter { fillerSpellings[$0] == nil && !russianFillers.contains($0) }
            guard nonFillers.count >= 2 else { return nil }
            if language == .other, words.count == 2, questionAuxiliaries.contains(words[0]), questionSubjects.contains(words[1]),
               text.last?.isLetter == true { return nil }
            return (anchor, language)
        }
        return segments.map { segment in
            guard let alternative = replacements[segment.id] else { return segment }
            func gap(_ anchor: TranscriptSegment) -> Double { max(0, max(anchor.start - segment.end, segment.start - anchor.end)) }
            let nearby = anchors.filter { $0.segment.id != segment.id && gap($0.segment) <= 60 }
            let segmentTrack = track(segment)
            var revised = segment
            revised.text = alternative
            // Overlapping Russian speech can establish the context for a
            // neutral sound or an acoustically corroborated Russian reading.
            let supportedAcknowledgment = alternatives[segment.id] == alternative && russianSpelling(ofFiller: segment.text) != nil
            if nearby.contains(where: { $0.language == .russian && track($0.segment) != segmentTrack
                && $0.segment.start < segment.end && segment.start < $0.segment.end }),
               !nearby.contains(where: { $0.language == .other && gap($0.segment) <= 2 }),
               isNeutralVocalization(segment.text) || supportedAcknowledgment || verifiedLexical[segment.id] != nil
                    || (unconfirmed.contains(segment.id) && shortMixedFragment(segment.text,
                        duration: segment.end - segment.start, vocabulary: vocabulary)) {
                return revised
            }
            let sameTrack = nearby.filter { track($0.segment) == segmentTrack }
            let relevant = sameTrack.isEmpty ? nearby : sameTrack
            guard let nearest = relevant.map({ gap($0.segment) }).min() else { return segment }
            let closest = relevant.filter { gap($0.segment) == nearest }
            if !closest.allSatisfy({ $0.language == .russian }) {
                // An unknown name or a clipped Cyrillic phrase does not
                // establish a language switch. Require Russian speech on
                // *both* sides nearby; audible foreign speech still vetoes it.
                guard !closest.contains(where: { $0.language == .other }) else { return segment }
                let decisive = relevant.filter { $0.language != .uncertain && gap($0.segment) <= 10 }
                let left = decisive.filter { $0.segment.start <= segment.start }
                let right = decisive.filter { $0.segment.start > segment.start }
                func nearestIsRussian(_ side: [(segment: TranscriptSegment, language: ConversationLanguage)]) -> Bool {
                    guard let best = side.map({ gap($0.segment) }).min() else { return false }
                    return side.filter { gap($0.segment) == best }.allSatisfy { $0.language == .russian }
                }
                guard nearestIsRussian(left), nearestIsRussian(right) else { return segment }
            }
            return revised
        }
    }

    private static func isNeutralVocalization(_ text: String) -> Bool {
        let words = RussianRecognition.words(text).filter { !russianFillers.contains($0) }
        return !words.isEmpty && words.allSatisfy(neutralVocalizations.contains)
    }

    private static func isOpenVowel(_ word: String) -> Bool {
        word.allSatisfy { $0 == "а" }
    }

    private static func localizedFiller(_ text: String) -> String? {
        guard let spelling = russianSpelling(ofFiller: text) else { return nil }
        let words = RussianRecognition.words(text)
        guard words.contains(where: { fillerSpellings[$0] != nil }) else { return nil }
        let sentencePunctuation = CharacterSet(charactersIn: ".!?…")
        let body = text.trimmingCharacters(in: sentencePunctuation.union(.whitespacesAndNewlines))
        let distinctSentences = body.rangeOfCharacter(from: sentencePunctuation) != nil
            && Set(spelling.components(separatedBy: ", ")).count > 1
        if words.contains(where: russianFillers.contains) || distinctSentences {
            let matches = fillerWords.matches(in: text, range: NSRange(text.startIndex..., in: text))
            let source = text as NSString
            let result = NSMutableString(string: text)
            var edits: [(NSRange, String)] = []
            var index = 0
            while index < matches.count {
                let current = matches[index].range
                let word = source.substring(with: current)
                var range = current
                var replacement = fillerSpellings[word.lowercased()]
                if index + 1 < matches.count {
                    let next = matches[index + 1].range
                    let separator = source.substring(with: NSRange(location: NSMaxRange(current), length: next.location - NSMaxRange(current)))
                    let pair = word.lowercased() + " " + source.substring(with: next).lowercased()
                    if separator.allSatisfy({ $0.isWhitespace || "-‐‑".contains($0) }), let paired = fillerSpellings[pair] {
                        range = NSUnionRange(current, next)
                        replacement = paired
                        index += 1
                    }
                }
                if let replacement {
                    let cased = word.first?.isUppercase == true ? replacement.prefix(1).uppercased() + replacement.dropFirst() : replacement
                    edits.append((range, cased))
                }
                index += 1
            }
            for (range, replacement) in edits.reversed() { result.replaceCharacters(in: range, with: replacement) }
            return result as String
        }
        let punctuation = text.trimmingCharacters(in: .whitespacesAndNewlines).reversed().prefix { ".!?,:;…".contains($0) }
        return spelling.prefix(1).uppercased() + spelling.dropFirst() + String(punctuation.reversed())
    }

    static func russianSpelling(ofFiller text: String) -> String? {
        guard !containsLiteralMarks(text), text.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil else { return nil }
        return fillerSpelling(RussianRecognition.words(text))
    }

    static func isVocalization(_ text: String) -> Bool {
        isAmbiguous(RussianRecognition.words(text))
    }

    private static func containsLiteralMarks(_ text: String) -> Bool {
        literalMarks.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
    }

    private static func fillerSpelling(_ words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        var spellings: [String] = []
        var index = 0
        while index < words.count {
            let pair = words[index...].prefix(2).joined(separator: " ")
            if index + 1 < words.count, let spelling = fillerSpellings[pair] {
                spellings.append(spelling)
                index += 2
            } else {
                guard let spelling = fillerSpellings[words[index]] ?? (russianFillers.contains(words[index]) ? words[index] : nil) else { return nil }
                spellings.append(spelling)
                index += 1
            }
        }
        return spellings.joined(separator: ", ")
    }

    private static func track(_ segment: TranscriptSegment) -> String {
        if segment.audioFile?.contains("-mic.") == true { return "mic" }
        if segment.audioFile?.contains("-remote.") == true { return "remote" }
        return segment.speaker
    }

    private enum ConversationLanguage { case russian, other, uncertain }

    static func isRussianContext(_ text: String) -> Bool {
        let words = RussianRecognition.words(text)
        return words.count >= 4 && conversationLanguage(text, words: words) == .russian
    }

    private static func conversationLanguage(_ text: String, words: [String]) -> ConversationLanguage? {
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x052F).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }.count
        if cyrillic > 0, cyrillic >= latin * 2 {
            guard !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(text) else { return .other }
            // Several Slavic languages share these letters. Look for actual
            // known words beyond the short particles shared by those languages.
            // Latin product names cannot be dictionary evidence against the
            // surrounding Russian clause. The script ratio above still
            // distinguishes predominantly foreign turns.
            let cyrillicWords = words.filter { word in
                word.unicodeScalars.allSatisfy { (0x430...0x44f).contains($0.value) }
            }
            let content = cyrillicWords.filter { $0.count >= 4 }
            let evidence = content.isEmpty ? cyrillicWords : content
            let known = evidence.filter(TranscriptTerms.isCommonRussianWord)
            if known.count * 2 > evidence.count { return .russian }
            // Technical nouns and names are often missing from the common-form
            // dictionary. Count the surrounding Russian words too when the
            // content words alone are inconclusive.
            let shortKnown = words.filter {
                $0.count < 4 && (TranscriptTerms.isCommonRussianWord($0) || AbbreviationFamilies.isRussianFunctionWord($0))
            }.count
            if !known.isEmpty, !content.isEmpty, words.contains(where: russianContextWords.contains), shortKnown > 0,
               known.count * 2 == content.count || (known.count + shortKnown) * 3 >= cyrillicWords.count * 2 { return .russian }
            return .uncertain
        }
        if latin > 0, latin >= cyrillic * 2 { return .other }
        return nil
    }
}
