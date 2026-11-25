import Foundation

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
