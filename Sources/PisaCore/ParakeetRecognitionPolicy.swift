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

    static func needsVerification(_ text: String) -> Bool {
        attribution.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    enum Decision: Equatable {
        case keep, silence, unclear, speech(String)
    }

    // Models may spell the same username in different scripts or split it
    // into a first and last name. Compare the complete credited name.
    private static func comparisonWords(_ text: String) -> [String] {
        let words = RussianRecognition.words(text)
        guard needsVerification(text) else { return words }
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
        let contradictions = readings.indices.filter { i in
            if needsVerification(readings[i]) { return words[i].last != original.last }
            return !words[i].contains { $0.hasPrefix("субтитр") || ["subtitle", "subtitles", "caption", "captions"].contains($0) }
        }.count
        guard silent + contradictions >= 2 else { return .keep }
        if let acoustic, let verifier, language?.lowercased() == "russian",
           confirmsAcousticTurn(acoustic, verifier: verifier, expandedPrimary: expandedPrimary) {
            return .speech(acoustic)
        }
        return .unclear
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
        guard positions.count == 1, let start = positions.first,
              start == 0 || !negations.contains(wide[start - 1]) else { return false }
        // Individually repeated content words can belong to a neighboring
        // occurrence even if punctuation and segmentation produce one match.
        return Set(anchors).allSatisfy { key in
            wide.filter { $0 == key }.count == heard.filter { $0 == key }.count
        }
    }
}
