import Foundation

/// Language-neutral vocal acknowledgments need nearby conversation context.
/// Known fillers can use a Russian spelling when a new audio decode is inconclusive.
enum BackchannelLanguage {
    private static let latinVocalizations: Set<String> = ["ah", "uh", "huh", "uhhuh", "hmm", "hm", "mm", "mhm", "mmhmm", "uhum", "um", "ajá"]
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
    private static let briefCyrillicReply = try! NSRegularExpression(pattern: #"^([А-ЯЁа-яё][а-яё]{1,2}) +[а-яё]{4,}[.!?…]*$"#)
    private static let lexicalWordLimit = 12
    // A diarized region fits in one 30-second model input. Longer lexical
    // routes apply to sentences, rather than labels and lists of product names.
    private static let sentenceMarkers = shortSentenceWords.union(["the", "this", "that", "these", "those", "please", "my", "your", "our", "let"])

    static func shouldRecheck(_ text: String, duration: Double) -> Bool {
        guard duration <= 3, !containsLiteralMarks(text), !isStandaloneLatinTerm(text) else { return false }
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

    static func isBriefCyrillicSource(_ text: String, vocabulary: String) -> Bool {
        guard briefCyrillicReply.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return false }
        let words = RussianRecognition.words(text)
        return words.count == 2 && !TranscriptTerms.isCommonRussianWord(words[0])
            && !AbbreviationFamilies.isRussianFunctionWord(words[0]) && TranscriptTerms.isCommonRussianWord(words[1])
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    // A compact transliteration or accented Latin reading can contain one
    // Russian word or even both scripts within the same word. Never mark this
    // class unclear on language disagreement: it includes genuine code-switches.
    static func shouldVerifyMixedLatin(_ text: String, duration: Double, vocabulary: String) -> Bool {
        guard (0...6).contains(duration) else { return false }
        let letters = text.unicodeScalars.filter(CharacterSet.letters.contains)
        guard letters.contains(where: { !$0.isASCII }) else { return false }
        let latin = latinLetter.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        guard latin * 2 > letters.count || shortVocalizationBeforeRussianWord(text),
              !MeetingSpeechText.containsForeignLetters(text), !containsLiteralMarks(text),
              text.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil else { return false }
        let words = text.split(whereSeparator: { !$0.isLetter })
        return (2...lexicalWordLimit).contains(words.count)
            && words.filter({ word in word.unicodeScalars.allSatisfy { (0x400...0x52f).contains($0.value) } }).count <= 1
            && !words.contains(where: { $0.dropFirst().contains(where: \.isUppercase) })
            && !words.dropFirst().contains(where: { $0.first?.isUppercase == true })
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    private static func shortVocalizationBeforeRussianWord(_ text: String) -> Bool {
        let words = RussianRecognition.words(text)
        return words.count == 2 && latinVocalizations.contains(words[0]) && words[1].count >= 3
            && TranscriptTerms.isCommonRussianWord(words[1])
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
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
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
        return agreedRussianText(russian, corroboration: corroboration)
    }

    static func agreedRussianText(_ russian: String, corroboration: String?) -> String? {
        let words = RussianRecognition.words(russian)
        guard let corroboration, !words.isEmpty,
              words.joined().unicodeScalars.allSatisfy({ (0x0430...0x044F).contains($0.value) }),
              words == RussianRecognition.words(corroboration) else { return nil }
        return russian.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Independent agreement preserves foreign Latin speech regardless of its
    /// language label. Punctuation and case do not change the spoken words.
    static func confirmsLatinSource(original: String, reread: String) -> Bool {
        guard [original, reread].allSatisfy({
            latinSpeech.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }) else { return false }
        let words = RussianRecognition.words(original), checked = RussianRecognition.words(reread)
        guard !words.isEmpty else { return false }
        if words == checked { return true }
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
        let particles: Set<String> = ["я", "ну", "а", "и"]
        let substantive = words.filter { !particles.contains($0) }
        let independent = RussianRecognition.words(corroboration).filter { !particles.contains($0) }
        return !substantive.isEmpty && substantive == independent ? russian : nil
    }

    static func resolve(_ segments: [TranscriptSegment], alternatives: [UUID: String], lexicalAlternatives: [UUID: String] = [:],
                        uncertain: Set<UUID> = [], preceding: [TranscriptSegment], vocabulary: String = "") -> [TranscriptSegment] {
        var verifiedLexical: [UUID: String] = [:]
        var unconfirmed: Set<UUID> = []
        for segment in segments {
            let candidate = lexicalAlternatives[segment.id]
            let isUncertain = uncertain.contains(segment.id)
            if let candidate, shouldVerifyMixedLatin(segment.text, duration: segment.end - segment.start, vocabulary: vocabulary)
                || mixedWordIndex(segment.text, duration: segment.end - segment.start, vocabulary: vocabulary) != nil {
                verifiedLexical[segment.id] = candidate
                continue
            }
            guard candidate != nil || isUncertain,
                  shouldRecheckLexical(segment.text, duration: segment.end - segment.start, vocabulary: vocabulary) else { continue }
            verifiedLexical[segment.id] = candidate
            if isUncertain { unconfirmed.insert(segment.id) }
        }
        var replacements: [UUID: String] = [:]
        for segment in segments {
            let audio = shouldRecheck(segment.text, duration: segment.end - segment.start) ? alternatives[segment.id] : nil
            let fallback = unconfirmed.contains(segment.id) ? "Неразборчиво" : localizedFiller(segment.text)
            if let replacement = verifiedLexical[segment.id] ?? audio ?? fallback,
               RussianRecognition.preservesVocabulary(candidate: replacement, original: segment.text, vocabulary: vocabulary) {
                replacements[segment.id] = replacement
            }
        }
        guard !replacements.isEmpty else { return segments }
        let anchors = (preceding + segments).compactMap { anchor -> (segment: TranscriptSegment, language: ConversationLanguage)? in
            // The proposed correction and quoted material cannot establish
            // the conversation language on which that correction depends.
            guard verifiedLexical[anchor.id] == nil, !unconfirmed.contains(anchor.id) else { return nil }
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
            let sameTrack = nearby.filter { track($0.segment) == track(segment) }
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
            var revised = segment; revised.text = alternative; return revised
        }
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
        guard !containsLiteralMarks(text) else { return nil }
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
