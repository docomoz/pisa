import Foundation

/// Language-neutral vocal acknowledgments need nearby conversation context.
/// Known fillers can use a Russian spelling when a new audio decode is inconclusive.
enum BackchannelLanguage {
    private static let englishVocalizations: Set<String> = ["ah", "uh", "huh", "uhhuh", "hmm", "hm", "mm", "mhm", "um"]
    private static let englishAffirmatives: Set<String> = ["yeah", "yep", "yes"]
    private static let englishOpenVowels: Set<String> = ["ah", "uh", "um"]
    private static let russianVocalizations: Set<String> = ["угу", "ага", "мгм", "хм", "мм", "м", "эм"]
    private static let fillerSpellings: [String: String] = [
        "ah": "а", "uh": "аааа", "um": "ааа", "huh": "а",
        "hmm": "хм", "hm": "хм", "mm": "мм", "mhm": "угу",
        "uh huh": "угу", "uhhuh": "угу", "mm hmm": "угу",
        "yes": "да", "yeah": "да", "yep": "да", "ok": "окей", "okay": "окей",
        "sorry": "сорри",
    ]
    private static let russianFillers = Set(fillerSpellings.values).union(russianVocalizations)
    private static let shortSentenceWords: Set<String> = [
        "i", "you", "he", "she", "we", "they", "it", "am", "is", "are", "was", "were", "do", "does", "did",
        "can", "could", "will", "would", "shall", "should", "what", "who", "where", "when", "why", "how",
        "я", "ты", "он", "она", "мы", "вы", "они", "это", "как", "где", "когда", "куда", "кто", "что", "почему",
    ]
    private static let literalMarks = try! NSRegularExpression(pattern:
        #"[/\\`"«»“”‘~@]|(?<![A-Za-z])['’]|['’](?![A-Za-z])|(?<=[A-Za-z])\.(?=[A-Za-z])"#)
    private static let fillerWords = try! NSRegularExpression(pattern: #"\p{L}+"#)
    private static let latinSpeech = try! NSRegularExpression(pattern: #"\A[\P{L}\p{Latin}]*\p{Latin}[\P{L}\p{Latin}]*\z"#)
    private static let lexicalLiteralMarks = CharacterSet(charactersIn: "_+#$%=<>[]{}|‹›„")
    private static let lexicalWordLimit = 12

    static func shouldRecheck(_ text: String, duration: Double) -> Bool {
        guard duration <= 3, !containsLiteralMarks(text) else { return false }
        let words = RussianRecognition.words(text)
        // Mixed filler chains need spelling edits that retain the Russian reply.
        if words.contains(where: russianFillers.contains) { return false }
        if fillerSpelling(words) != nil { return true }
        return (1...3).contains(words.count) && words.joined().unicodeScalars.allSatisfy {
            (0x61...0x7A).contains($0.value)
        }
    }

    static func shouldRecheckLexical(_ text: String, duration: Double, vocabulary: String = "") -> Bool {
        (0...6).contains(duration) && isLexicalSource(text, vocabulary: vocabulary)
    }

    private static func isLexicalSource(_ text: String, vocabulary: String) -> Bool {
        guard !containsLiteralMarks(text), text.rangeOfCharacter(from: lexicalLiteralMarks) == nil else { return false }
        let words = RussianRecognition.words(text)
        return (1...lexicalWordLimit).contains(words.count)
            && words.joined().unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) }
            && RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary)
    }

    /// The caller supplies unprompted multilingual recognition of the same audio.
    /// The independent Russian recognizer must corroborate every word.
    static func lexicalAlternative(original: String, russian: String, corroboration: String?, vocabulary: String = "") -> String? {
        guard isLexicalSource(original, vocabulary: vocabulary), let corroboration else { return nil }
        let words = RussianRecognition.words(russian)
        guard (1...lexicalWordLimit).contains(words.count),
              words.joined().unicodeScalars.allSatisfy({ (0x0430...0x044F).contains($0.value) }),
              words == RussianRecognition.words(corroboration) else { return nil }
        return russian.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Missing evidence from either recognizer cannot establish an empty turn.
    static func hasNoSpeechEvidence(language: String?, text: String, corroboration: String?) -> Bool {
        guard language?.lowercased() == "none", let corroboration else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && corroboration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func hasEnglishEvidence(language: String?, text: String) -> Bool {
        let language = language?.lowercased()
        guard language == "english" || language == "en" else { return false }
        return latinSpeech.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Independent agreement preserves foreign Latin speech regardless of its
    /// language label. Punctuation and case do not change the spoken words.
    static func confirmsLatinSource(original: String, reread: String) -> Bool {
        guard [original, reread].allSatisfy({
            latinSpeech.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
        }) else { return false }
        let words = RussianRecognition.words(original)
        return !words.isEmpty && words == RussianRecognition.words(reread)
    }

    /// A short lead-in can stabilize decoding without cutting or changing speech.
    static func retryAudio(_ samples: [Float]) -> [Float] {
        Array(repeating: 0, count: 2_000) + samples
    }

    private static func isAmbiguous(_ words: [String]) -> Bool {
        words.contains(where: englishVocalizations.contains) && words.allSatisfy {
            englishVocalizations.contains($0) || englishAffirmatives.contains($0)
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
            guard candidate != nil || isUncertain,
                  shouldRecheckLexical(segment.text, duration: segment.end - segment.start, vocabulary: vocabulary) else { continue }
            verifiedLexical[segment.id] = candidate
            if isUncertain { unconfirmed.insert(segment.id) }
        }
        let anchors = (preceding + segments).filter {
            // Suspect text and its possible corrections cannot establish the
            // conversation language on which those corrections depend.
            guard verifiedLexical[$0.id] == nil, !unconfirmed.contains($0.id) else { return false }
            let words = RussianRecognition.words($0.text)
            let isShortSentence = (2...3).contains(words.count) && words.contains(where: shortSentenceWords.contains)
                && !containsLiteralMarks($0.text)
            return (words.count >= 4 || isShortSentence) && fillerSpelling(words) == nil
                && !words.allSatisfy { russianFillers.contains($0) || isOpenVowel($0) }
                && language($0.text) != nil
        }
        return segments.map { segment in
            let audioAlternative = shouldRecheck(segment.text, duration: segment.end - segment.start) ? alternatives[segment.id] : nil
            let fallback = unconfirmed.contains(segment.id) ? "Неразборчиво" : localizedFiller(segment.text)
            guard let alternative = verifiedLexical[segment.id] ?? audioAlternative ?? fallback,
                  RussianRecognition.preservesVocabulary(candidate: alternative, original: segment.text, vocabulary: vocabulary) else { return segment }
            func gap(_ anchor: TranscriptSegment) -> Double { max(0, max(anchor.start - segment.end, segment.start - anchor.end)) }
            let nearby = anchors.filter { $0.id != segment.id && gap($0) <= 60 }
            let sameTrack = nearby.filter { track($0) == track(segment) }
            guard let closest = (sameTrack.isEmpty ? nearby : sameTrack).min(by: { gap($0) < gap($1) }),
                  language(closest.text) == "Russian" else { return segment }
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
        if words.contains(where: russianFillers.contains) {
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
        let punctuation = text.trimmingCharacters(in: .whitespacesAndNewlines).reversed().prefix { ".!?…".contains($0) }
        return spelling.prefix(1).uppercased() + spelling.dropFirst() + String(punctuation.reversed())
    }

    static func russianSpelling(ofFiller text: String) -> String? {
        guard !containsLiteralMarks(text) else { return nil }
        return fillerSpelling(RussianRecognition.words(text))
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

    private static func language(_ text: String) -> String? {
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x052F).contains($0.value) }.count
        let latin = text.unicodeScalars.filter { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }.count
        if cyrillic > 0, cyrillic >= latin * 2 { return "Russian" }
        if latin > 0, latin >= cyrillic * 2 { return "English" }
        return nil
    }
}
