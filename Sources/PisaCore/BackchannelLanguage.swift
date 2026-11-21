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
        guard latin * 2 > letters.count,
              !MeetingSpeechText.containsForeignLetters(text), !containsLiteralMarks(text),
              text.rangeOfCharacter(from: lexicalLiteralMarks.union(.decimalDigits)) == nil else { return false }
        let words = text.split(whereSeparator: { !$0.isLetter })
        return (2...lexicalWordLimit).contains(words.count)
            && words.filter({ word in word.unicodeScalars.allSatisfy { (0x400...0x52f).contains($0.value) } }).count <= 1
            && !words.contains(where: { $0.dropFirst().contains(where: \.isUppercase) })
            && !words.dropFirst().contains(where: { $0.first?.isUppercase == true })
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    static func canRestoreLanguageAnchor(_ segment: TranscriptSegment) -> Bool {
        // Older live drafts have no provenance. Lexical substitutions in
        // those builds were restricted to at most six seconds.
        segment.independentRecognitionLanguage ?? (segment.end - segment.start > 6)
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
        func evidence(_ text: String) -> String? {
            let input = text.lowercased()
                .replacingOccurrences(of: "о'кей", with: "окей")
                .replacingOccurrences(of: "о’кей", with: "окей")
            guard !containsLiteralMarks(input) else { return nil }
            let words = RussianRecognition.words(input).map { ["okei", "okey"].contains($0) ? "okay" : $0 }
            return fillerSpelling(words)
        }
        return source == evidence(reread) && source == evidence(corroboration)
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
            if let candidate, shouldVerifyMixedLatin(segment.text, duration: segment.end - segment.start, vocabulary: vocabulary) {
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
        let anchors = (preceding + segments).compactMap { anchor -> (segment: TranscriptSegment, russian: Bool)? in
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
                  let russian = russianConversationEvidence(text, words: words) else { return nil }
            // In a run of acknowledgments, one stray syllable does not establish
            // a language switch. Nor does an unfinished subject/auxiliary pair.
            let nonFillers = words.filter { fillerSpellings[$0] == nil && !russianFillers.contains($0) }
            guard nonFillers.count >= 2 else { return nil }
            if !russian, words.count == 2, questionAuxiliaries.contains(words[0]), questionSubjects.contains(words[1]),
               text.last?.isLetter == true { return nil }
            return (anchor, russian)
        }
        return segments.map { segment in
            guard let alternative = replacements[segment.id] else { return segment }
            func gap(_ anchor: TranscriptSegment) -> Double { max(0, max(anchor.start - segment.end, segment.start - anchor.end)) }
            let nearby = anchors.filter { $0.segment.id != segment.id && gap($0.segment) <= 60 }
            let sameTrack = nearby.filter { track($0.segment) == track(segment) }
            let relevant = sameTrack.isEmpty ? nearby : sameTrack
            guard let nearest = relevant.map({ gap($0.segment) }).min(),
                  relevant.filter({ gap($0.segment) == nearest }).allSatisfy(\.russian) else { return segment }
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

    private static func russianConversationEvidence(_ text: String, words: [String]) -> Bool? {
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x052F).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }.count
        if cyrillic > 0, cyrillic >= latin * 2 {
            guard !ParakeetRecognitionPolicy.hasDistinctCyrillicLetters(text) else { return false }
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
            if known.count * 2 > evidence.count { return true }
            // Technical nouns and names are often missing from the common-form
            // dictionary. Count the surrounding Russian words too when the
            // content words alone are inconclusive.
            guard !known.isEmpty, !content.isEmpty, words.contains(where: russianContextWords.contains) else { return false }
            let shortKnown = words.filter {
                $0.count < 4 && (TranscriptTerms.isCommonRussianWord($0) || AbbreviationFamilies.isRussianFunctionWord($0))
            }.count
            return shortKnown > 0 && (known.count * 2 == content.count || (known.count + shortKnown) * 3 >= cyrillicWords.count * 2)
        }
        if latin > 0, latin >= cyrillic * 2 { return false }
        return nil
    }
}
