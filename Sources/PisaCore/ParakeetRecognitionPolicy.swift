import Foundation
import NaturalLanguage

/// Text evidence routes conservative Russian repairs; it is not an ASR
/// language label. Foreign sentences are never translated by this policy.
enum ParakeetRecognitionPolicy {
    static let distinctCyrillicLetters = CharacterSet(charactersIn: "іїєґўІЇЄҐЎ")

    static func hasDistinctCyrillicLetters(_ text: String) -> Bool {
        text.rangeOfCharacter(from: distinctCyrillicLetters) != nil
    }

    static func hasRussianTextEvidence(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Distinct Ukrainian/Belarusian letters are positive evidence against
        // treating a supported foreign utterance as Russian.
        if hasDistinctCyrillicLetters(lower) {
            // A minority foreign name must not veto clear Russian evidence in
            // the surrounding turn. Without that evidence, abstain.
            let words = lower.split(whereSeparator: { !$0.isLetter })
            guard words.contains(where: { word in
                word.rangeOfCharacter(from: distinctCyrillicLetters) == nil
                    && word.contains(where: { "ыэъё".contains($0) })
            }) else { return false }
        }
        return lower.unicodeScalars.contains { (0x430...0x44F).contains($0.value) || $0.value == 0x451 }
    }

    static func verifierDirectory(explicit: URL?, speakerDirectory: URL) -> URL {
        explicit ?? speakerDirectory.deletingLastPathComponent().appendingPathComponent(SpeechModelFiles.verifierDirectoryName)
    }

    static func verifierCheckpointFiles(directory: URL, speakerDirectory: URL) -> [URL] {
        let managed = verifierDirectory(explicit: nil, speakerDirectory: speakerDirectory)
        var names = ["config.json", "model.safetensors", "tokenizer_config.json", "vocab.json", "merges.txt"]
        // Managed Qwen ships the pinned tokenizer sources. Its loader creates
        // tokenizer.json lazily; that derived file must not invalidate resume.
        // A custom folder can contain an authored tokenizer, which stays part
        // of its identity even when source vocab/merges are also supplied.
        if directory.standardizedFileURL != managed.standardizedFileURL { names.append("tokenizer.json") }
        return names.map { directory.appendingPathComponent($0) }
    }

    static let checkpointVariants = [
        "primary": ["parakeet-tdt-v3", "weights-float32", "audio-float32"],
        "verifier": ["qwen-selective"]
    ]
}

/// Final language evidence for newly recognized meeting speech. An ambiguous
/// ASCII word, product name, or short shared Cyrillic spelling is not evidence
/// of another language. The glossary only exempts the exact terms it contains.
enum MeetingRecognitionLanguage {
    private enum Script {
        case latin, cyrillic, other
    }

    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}_][\p{L}\p{M}\p{N}_]*(?:['’‐‑-][\p{L}\p{N}][\p{L}\p{M}\p{N}_]*)*"#)
    private static let latin = try! NSRegularExpression(pattern: #"\A[\p{Latin}\p{M}'’‐‑-]+\z"#)
    private static let cyrillic = try! NSRegularExpression(pattern: #"\A[\p{Cyrillic}\p{M}'’‐‑-]+\z"#)
    private static let identifier = try! NSRegularExpression(pattern:
        #"(?:[\p{L}\p{N}_.-]+[/\\])+[\p{L}\p{M}\p{N}_.-]+|[\p{L}\p{M}\p{N}]*_[\p{L}\p{M}\p{N}_]+"#)
    private static let evidenceToken = try! NSRegularExpression(pattern:
        #"\p{N}+(?:[.,]\p{N}+)+|[\p{L}\p{N}_][\p{L}\p{M}\p{N}_]*(?:['’‐‑-][\p{L}\p{N}][\p{L}\p{M}\p{N}_]*)*|[\p{Sc}%‰‱±+−–\-#/@*<>=|\\&]"#)
    private static let englishLoans: Set<String> = [
        "café", "cafés", "cliché", "clichés", "déjà", "fiancé", "fiancée", "fiancés", "fiancées",
        "naïve", "naïveté", "résumé", "résumés", "façade", "piñata", "touché",
    ]
    // Frequent English function words distinguish natural speech from a list
    // of unfamiliar technical names without running a model on every term.
    private static let englishGrammar: Set<String> = [
        "the", "this", "these", "those", "they", "their", "we", "your", "would", "should", "please", "let's",
    ]

    private struct Word {
        let range: NSRange
        let script: Script?
        var suspect: Bool
    }

    private static func inspect(_ token: String, range: NSRange) -> Word {
        let scalars = token.unicodeScalars
        var letters = 0, ascii = 0, russian = 0
        for scalar in scalars where CharacterSet.letters.contains(scalar) {
            letters += 1
            if scalar.isASCII { ascii += 1 }
            if (0x410...0x44f).contains(scalar.value) || scalar.value == 0x401 || scalar.value == 0x451 { russian += 1 }
        }
        // Digits, identifier fragments, and genuine RU/EN compounds serve as
        // boundaries when asking the sentence classifier about ordinary speech.
        if letters == 0 || token.contains("_") || (token.first?.isLowercase == true && token.dropFirst().contains(where: \.isUppercase)) {
            return Word(range: range, script: nil, suspect: false)
        }
        if ascii + russian == letters && !scalars.contains(where: { CharacterSet.nonBaseCharacters.contains($0) && $0.value != 0x301 }) {
            let script: Script? = ascii == letters ? .latin : russian == letters ? .cyrillic : nil
            let identifier = token.contains(where: \.isNumber) || token.dropFirst().contains(where: \.isUppercase)
            return Word(range: range, script: identifier ? nil : script, suspect: false)
        }
        let full = NSRange(location: 0, length: token.utf16.count)
        let script: Script = latin.firstMatch(in: token, range: full) != nil ? .latin
            : cyrillic.firstMatch(in: token, range: full) != nil ? .cyrillic : .other
        return Word(range: range, script: script, suspect: true)
    }

    private static func glossaryRanges(_ text: String, vocabulary: String) -> [NSRange] {
        let entries = vocabulary.precomposedStringWithCanonicalMapping.components(separatedBy: CharacterSet(charactersIn: ",;\r\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !entries.isEmpty else { return [] }
        let alternatives = entries.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?<![\p{L}\p{M}\p{N}_])(?:"# + alternatives + #")(?![\p{L}\p{M}\p{N}_])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private static func literals(_ text: String) -> [NSRange] {
        let source = text as NSString
        let technical = TranscriptOrthography.literalRanges(in: text).flatMap { range -> [NSRange] in
            let fragment = source.substring(with: range)
            // ASR may add prose quotation marks around ordinary speech. A
            // URL or code span inside such a quotation still has its own range.
            guard let opener = fragment.first, "\"'«“‘".contains(opener) else { return [range] }
            let inside = String(fragment.dropFirst().dropLast())
            return literals(inside).map { NSRange(location: range.location + 1 + $0.location, length: $0.length) }
        }
        return technical + identifier.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
    }

    private struct Damage {
        let spans: [NSRange]
        let whole: Bool
    }

    private static func damage(in text: String, vocabulary: String) -> Damage? {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let matches = word.matches(in: text, range: full)
        func classifyWords(protecting protected: [NSRange]) -> [Word] {
            var words = matches.map { match in
                if protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    return Word(range: match.range, script: nil, suspect: false)
                }
                return inspect(source.substring(with: match.range), range: match.range)
            }
            var start = 0
            while start < words.count {
                let script = words[start].script
                var end = start + 1
                // Punctuation and a switch of script bound the language evidence.
                // One foreign sentence cannot remove a neighboring Russian turn.
                if script == .latin || script == .cyrillic {
                    while end < words.count, words[end].script == script {
                        let after = NSMaxRange(words[end - 1].range)
                        let gap = source.substring(with: NSRange(location: after, length: words[end].range.location - after))
                        guard gap.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) else { break }
                        end += 1
                    }
                    classify(&words, from: start, to: end, in: source)
                }
                start = end
            }
            return words
        }
        var words = classifyWords(protecting: [])
        guard words.contains(where: \.suspect) else { return nil }
        let protected = literals(text) + glossaryRanges(text, vocabulary: vocabulary)
        if !protected.isEmpty { words = classifyWords(protecting: protected) }
        var spans: [NSRange] = []
        for w in words where w.suspect {
            if let previous = spans.last {
                let after = NSMaxRange(previous)
                let gap = source.substring(with: NSRange(location: after, length: w.range.location - after))
                if gap.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) {
                    spans[spans.count - 1] = NSUnionRange(previous, w.range)
                    continue
                }
            }
            spans.append(w.range)
        }
        guard !spans.isEmpty else { return nil }
        let whole = evidenceToken.matches(in: text, range: full).allSatisfy { token in
            spans.contains { NSIntersectionRange(token.range, $0).length == token.range.length }
        }
        return Damage(spans: spans, whole: whole)
    }

    private static func classify(_ words: inout [Word], from start: Int, to end: Int, in source: NSString) {
        let run = start..<end
        let tokens = words[run]
        let count = run.count
        let first = words[start]
        if count == 1, first.suspect, first.script == .latin,
           englishLoans.contains(source.substring(with: first.range).lowercased()) { words[start].suspect = false }
        let unknownCyrillic = count == 1 && first.script == .cyrillic && !first.suspect && first.range.length >= 5
            && !TranscriptTerms.isCommonRussianWord(source.substring(with: first.range).lowercased().replacingOccurrences(of: "ё", with: "е"))
        guard count >= 2 || unknownCyrillic else { return }
        let span = NSUnionRange(first.range, words[end - 1].range)
        guard count == 1 || span.length >= 10 else { return }
        if count > 1 && tokens.dropFirst().allSatisfy({ source.substring(with: $0.range).first?.isUppercase == true }) { return }
        if first.script == .cyrillic && !unknownCyrillic && tokens.allSatisfy({ token in
            guard !token.suspect else { return false }
            let key = source.substring(with: token.range).lowercased().replacingOccurrences(of: "ё", with: "е")
            return AbbreviationFamilies.isRussianFunctionWord(key) || TranscriptTerms.isCommonRussianWord(key)
        }) { return }
        let hasAccent = tokens.contains(where: \.suspect)
        let english = first.script == .latin && tokens.contains { englishGrammar.contains(source.substring(with: $0.range).lowercased()) }
        if english && !hasAccent { return }
        let clause = source.substring(with: span)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(clause)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2)
        if let (language, probability) = hypotheses.max(by: { $0.value < $1.value }),
           language != .russian, language != .english, language != .undetermined,
           probability >= (count == 1 ? 0.99 : count == 2 ? 0.93 : 0.90), !english {
            for i in run { words[i].suspect = true }
        } else if hasAccent && first.script == .latin {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = clause
            tagger.setLanguage(.english, range: clause.startIndex..<clause.endIndex)
            for i in run where words[i].suspect {
                let token = source.substring(with: words[i].range)
                if englishLoans.contains(token.lowercased()) {
                    words[i].suspect = false
                    continue
                }
                guard (english || hypotheses[.english, default: 0] >= 0.65), token.first?.isUppercase == true,
                      let index = Range(NSRange(location: words[i].range.location - span.location, length: words[i].range.length), in: clause)?.lowerBound else { continue }
                let tag = tagger.tag(at: index, unit: .word, scheme: .nameType).0
                let adjacentName = [i - 1, i + 1].contains { j in
                    run.contains(j) && source.substring(with: words[j].range).first?.isUppercase == true
                }
                if adjacentName || tag == .personalName || tag == .placeName || tag == .organizationName {
                    words[i].suspect = false
                }
            }
        }
    }

    static func unclearText(for text: String, vocabulary: String) -> String? {
        let text = text.precomposedStringWithCanonicalMapping
        guard let damage = damage(in: text, vocabulary: vocabulary) else { return nil }
        if damage.whole { return "Неразборчиво" }
        let result = NSMutableString(string: text)
        for var range in damage.spans.reversed() {
            if NSMaxRange(range) < result.length, result.character(at: NSMaxRange(range)) == 46 { range.length += 1 }
            result.replaceCharacters(in: range, with: "…")
        }
        return result as String
    }

    private struct Reading {
        let source: NSString
        let ranges: [NSRange]
        let keys: [String]
        let literalValues: [String]

        init(_ text: String) {
            let source = text as NSString
            self.source = source
            ranges = evidenceToken.matches(in: text, range: NSRange(location: 0, length: source.length)).map(\.range)
            keys = ranges.map { source.substring(with: $0).lowercased().replacingOccurrences(of: "ё", with: "е") }
            literalValues = literals(text).map { source.substring(with: $0) }
        }
    }

    /// Both arguments are unprompted readings of the same audio from
    /// independent models. Exact agreement supplies every replacement word.
    static func confirmedText(_ candidate: String, corroboration: String?, original: String, vocabulary: String) -> String? {
        guard let corroboration else { return nil }
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let original = original.precomposedStringWithCanonicalMapping
        guard let damage = damage(in: original, vocabulary: vocabulary),
              damage.whole || damage.spans.count == 1,
              unclearText(for: candidate, vocabulary: vocabulary) == nil else { return nil }
        let heard = Reading(candidate), checked = Reading(corroboration.precomposedStringWithCanonicalMapping)
        guard !heard.keys.isEmpty, heard.keys == checked.keys, heard.literalValues == checked.literalValues else { return nil }
        let old = Reading(original), disputed = damage.spans[0]
        let prefix = damage.whole ? 0 : old.ranges.prefix { NSMaxRange($0) <= disputed.location }.count
        let suffix = damage.whole ? 0 : old.ranges.reversed().prefix { $0.location >= NSMaxRange(disputed) }.count
        guard heard.keys.count > prefix + suffix,
              old.keys.prefix(prefix) == heard.keys.prefix(prefix), old.keys.suffix(suffix) == heard.keys.suffix(suffix) else { return nil }
        let newWords = prefix..<(heard.keys.count - suffix)
        guard newWords.contains(where: { index in
            heard.keys[index] != "неразборчиво" && heard.keys[index].contains { $0.isLetter || $0.isNumber }
        }) else { return nil }
        if damage.whole { return candidate }
        let replacement = NSUnionRange(heard.ranges[prefix], heard.ranges[newWords.upperBound - 1])
        return old.source.replacingCharacters(in: disputed, with: heard.source.substring(with: replacement))
    }

    /// A short isolated verifier read can agree with a whole final sentence
    /// of both other decoders while they hear different lead-ins at the cut.
    static func confirmedEnding(_ reread: String, primary: String, acoustic: String?, original: String, vocabulary: String) -> String? {
        guard let acoustic, Reading(original).keys.count == 1,
              unclearText(for: original, vocabulary: vocabulary) == "Неразборчиво",
              Reading(reread).keys.count == 1,
              reread.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)).unicodeScalars.allSatisfy({
                  (0x410...0x44f).contains($0.value) || $0.value == 0x401 || $0.value == 0x451
              }) else { return nil }
        func ending(_ text: String) -> (text: String, omittedSpeech: Bool)? {
            let read = Reading(text)
            guard let last = read.ranges.last, read.keys.count <= 7 else { return nil }
            if read.keys.count > 1 {
                let previous = NSMaxRange(read.ranges[read.ranges.count - 2])
                let gap = read.source.substring(with: NSRange(location: previous, length: last.location - previous))
                guard gap.contains(where: { ".!?".contains($0) }),
                      read.keys.dropLast().allSatisfy({ (AbbreviationFamilies.isRussianFunctionWord($0) || TranscriptTerms.isCommonRussianWord($0))
                          && !RecognitionConsensus.isSensitiveAtCut($0) }) else { return nil }
            }
            return (read.source.substring(from: last.location), read.keys.count > 1)
        }
        guard let first = ending(primary), let second = ending(acoustic),
              confirmedText(reread, corroboration: first.text, original: original, vocabulary: vocabulary) != nil,
              let agreed = confirmedText(reread, corroboration: second.text, original: original, vocabulary: vocabulary) else { return nil }
        return first.omittedSpeech || second.omittedSpeech ? "… " + agreed : agreed
    }
}

/// A standalone attribution is a reason to listen again. It can also be
/// exactly what a participant said, including a nickname in another script.
enum RecognitionSubtitleCredit {
    private static let attribution = try! NSRegularExpression(pattern:
        #"(?i)^\s*(?:субтитры\s+(?:сделал[аи]?|подготовил[аи]?|создал[аи]?)|(?:автор|редактор|переводчик)\s+субтитров|(?:subtitles?|captions?)\s+by)[\s:—–-]+[\p{L}\p{N}_'’-]+(?:\s+[\p{L}\p{N}_'’-]+){0,3}[.!…]?\s*$"#)
    private static let closing = try! NSRegularExpression(pattern:
        #"(?i)^\s*(?:продолжение\s+следует|(?:спасибо|благодарим)\s+за\s+просмотр|to\s+be\s+continued|(?:thanks|thank\s+you)\s+for\s+watching)[.!?…]*\s*$"#)
    private static let word = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    private static let quantity = try! NSRegularExpression(pattern: #"[+±−–-]?\p{N}+(?:[.,]\p{N}+)*|[\p{Sc}%‰‱]"#)
    private static let withinClause = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ","))

    static func needsVerification(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return attribution.firstMatch(in: text, range: range) != nil || closing.firstMatch(in: text, range: range) != nil
    }

    enum Decision: Equatable {
        case keep, silence, unclear, speech(String)
    }

    // Models may spell the same username in different scripts or split it
    // into a first and last name. Compare the complete credited name.
    private static func comparisonWords(_ text: String) -> [String] {
        let words = RussianRecognition.words(text)
        let range = NSRange(text.startIndex..., in: text)
        guard attribution.firstMatch(in: text, range: range) != nil else {
            // Word tokenization drops minus signs, currencies and percentages.
            // Keep their order and normalize alternate minus/decimal spellings.
            let amounts = quantity.matches(in: text, range: range).compactMap { match -> String? in
                guard let r = Range(match.range, in: text) else { return nil }
                return String(text[r]).replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
            }
            return words + amounts
        }
        let author = words.dropFirst(2).joined()
        let latin = author.applyingTransform(.toLatin, reverse: false) ?? author
        return Array(words.prefix(2)) + [latin.folding(options: .diacriticInsensitive, locale: nil).lowercased()]
    }

    static func decision(for source: String, primary: String, verifier: String?, language: String?,
                         acoustic: String?, expandedPrimary: () -> String? = { nil }) -> Decision {
        guard needsVerification(source) else { return .keep }
        // An absent engine or a Qwen decode without a language is not a vote
        // for silence. Each engine contributes at most one unprompted reading.
        let primary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        let acoustic = acoustic?.trimmingCharacters(in: .whitespacesAndNewlines)
        let verifier = verifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let silent = [primary.isEmpty, acoustic == "", verifier == "" && language?.lowercased() == "none"]
            .filter { $0 }.count
        if silent >= 2 { return .silence }
        let readings = [primary, verifier, acoustic].compactMap { $0 }.filter {
            !$0.isEmpty && !MeetingSpeechText.containsForeignLetters($0) && $0.contains { $0.isLetter || $0.isNumber }
        }
        let original = comparisonWords(source)
        let words = readings.map(comparisonWords)
        for i in readings.indices {
            guard let matching = words[..<i].firstIndex(of: words[i]) else { continue }
            return words[i] == original ? .keep : .speech(readings[matching])
        }
        let isClosing = closing.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) != nil
        let contradictions = readings.indices.filter { i in
            if isClosing { return words[i] != original }
            if needsVerification(readings[i]) { return words[i].last != original.last }
            return !words[i].contains { $0.hasPrefix("субтитр") || ["subtitle", "subtitles", "caption", "captions"].contains($0) }
        }.count
        guard silent + contradictions >= 2 else { return .keep }
        if let acoustic, let verifier, language?.lowercased() == "russian" {
            if confirmsAcousticTurn(acoustic, verifier: verifier, expandedPrimary: expandedPrimary) {
                return .speech(acoustic)
            }
            if let suffix = agreedSuffix(acoustic, verifier: verifier) { return .speech(suffix) }
        }
        return .unclear
    }

    /// Both independent, unprompted reads of the exact turn can disagree on
    /// its onset while hearing the same sentence through the last word.
    private static func agreedSuffix(_ acoustic: String, verifier: String) -> String? {
        let texts = [acoustic, verifier]
        guard texts.allSatisfy({ text in
            !needsVerification(text) && text.allSatisfy { $0.isWhitespace || ",.!?…-‐‑".contains($0)
                || $0.unicodeScalars.allSatisfy { (0x0400...0x052F).contains($0.value) && CharacterSet.letters.contains($0) } }
        }) else { return nil }
        let heard = RussianRecognition.words(acoustic), checked = RussianRecognition.words(verifier)
        let count = zip(heard.reversed(), checked.reversed()).prefix { $0 == $1 }.count
        let suffix = heard.suffix(count)
        let anchors = suffix.filter { $0.count >= 4 && !AbbreviationFamilies.isRussianFunctionWord($0) }
        let missing = heard.dropLast(count) + checked.dropLast(count)
        guard count >= 5, Set(anchors).count >= 3, count * 3 >= max(heard.count, checked.count) * 2,
              max(heard.count, checked.count) - count <= 3,
              missing.allSatisfy({ TranscriptTerms.isCommonRussianWord($0) && !RecognitionConsensus.isSensitiveAtCut($0) })
        else { return nil }
        // Keep a whole new sentence when one decoder marks its onset. A
        // surviving verb phrase alone may have lost its subject or modality.
        guard texts.contains(where: { text in
            let spans = word.matches(in: text, range: NSRange(text.startIndex..., in: text))
            guard spans.count > count, let before = Range(spans[spans.count - count - 1].range, in: text),
                  let after = Range(spans[spans.count - count].range, in: text) else { return false }
            return text[before.upperBound..<after.lowerBound].contains(where: { ".!?…".contains($0) })
        }) else { return nil }
        let matches = word.matches(in: acoustic, range: NSRange(acoustic.startIndex..., in: acoustic))
        guard matches.count == heard.count, let match = matches.suffix(count).first,
              let range = Range(match.range, in: acoustic) else { return nil }
        return "… " + acoustic[range.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The isolated acoustic reading supplies every output word. A longer
    /// primary decode can confirm that interval but cannot contribute text
    /// from the speakers on either side of the cut.
    private static func confirmsAcousticTurn(_ acoustic: String, verifier: String, expandedPrimary: () -> String?) -> Bool {
        guard !needsVerification(acoustic), !needsVerification(verifier),
              acoustic.allSatisfy({ $0.isLetter || $0.isWhitespace || ",.!?…".contains($0) }) else { return false }
        let heard = RussianRecognition.words(acoustic), check = RussianRecognition.words(verifier)
        let anchors = heard.filter { $0.count >= 4 && !AbbreviationFamilies.isRussianFunctionWord($0) }
        guard heard.count >= 3, heard.allSatisfy({ word in word.unicodeScalars.allSatisfy { (0x430...0x44f).contains($0.value) } }),
              Set(anchors.filter(check.contains)).count >= 2 else { return false }
        let negations = ["не", "ни", "нет", "без"]
        guard heard.filter(negations.contains) == check.filter(negations.contains),
              let expanded = expandedPrimary() else { return false }
        let wide = RussianRecognition.words(expanded)
        let positions = wide.indices.filter { wide[$0...].starts(with: heard) }
        guard positions.count == 1, let start = positions.first else { return false }
        let spans = word.matches(in: expanded, range: NSRange(expanded.startIndex..., in: expanded)).compactMap { Range($0.range, in: expanded) }
        guard spans.count == wide.count else { return false }
        func joinsWords(at i: Int) -> Bool {
            expanded[spans[i - 1].upperBound..<spans[i].lowerBound].unicodeScalars.allSatisfy(withinClause.contains)
        }
        guard ((start + 1)..<(start + heard.count)).allSatisfy(joinsWords),
              start == 0 || !joinsWords(at: start) || !RecognitionConsensus.isSensitiveAtCut(wide[start - 1])
        else { return false }
        // Individually repeated content words can belong to a neighboring
        // occurrence even if punctuation and segmentation produce one match.
        return Set(anchors).allSatisfy { key in
            wide.filter { $0 == key }.count == heard.filter { $0 == key }.count
        }
    }
}
