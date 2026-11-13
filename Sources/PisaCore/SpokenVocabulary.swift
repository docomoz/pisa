import Foundation

/// Prepared once per user vocabulary. Only explicit dictionary entries are
/// eligible; pronunciations are derived locally, never saved as extra entries.
struct SpokenVocabulary {
    private struct Entry {
        var term: String
        var keys: Set<String>
        var initialism: Bool
        var cyrillicSpelling: String?
    }
    private struct Word { var text: String; var range: NSRange }
    private let vocabulary: String
    let decodingVocabulary: String
    private let terms: [String]
    private let entries: [Entry]
    private let phones: [String: [String]]
    private let explicitTerms: Set<String>
    private let cyrillicInitialisms: [(term: String, latin: String)]
    private let nameInstrumentals: [String]
    private static let standaloneWords: Set<String> = ["в", "во", "с", "со", "к", "и", "а", "у", "о", "на", "из", "от", "я", "ты", "мы", "он", "она", "они", "вы", "да", "но", "не", "же", "ли", "бы", "для", "по", "за"]

    init(_ vocabulary: String, pronunciations: String = "") {
        self.vocabulary = vocabulary
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        self.terms = terms
        func key(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
        }
        var seen = Set(terms.map(key))
        var bases: Set<String> = []
        var forms: [String] = []
        for term in terms where RecognitionVocabulary.numericForms(for: term) != nil {
            guard bases.count < 4 else { break }
            guard bases.insert(key(term)).inserted else { continue }
            // Keep the hint compact and in the glossary's list format. A
            // separate, exhaustive paradigm can bias short audio decodes.
            for ending in AbbreviationFamilies.promptEndings {
                let form = term + "'" + ending
                if seen.insert(key(form)).inserted { forms.append(form) }
            }
        }
        decodingVocabulary = forms.isEmpty ? vocabulary : vocabulary + ", " + forms.joined(separator: ", ")
        explicitTerms = Set(terms.map { $0.lowercased() })
        cyrillicInitialisms = terms.compactMap { term in
            guard (3...8).contains(term.count), Self.isRussianWord(term), term == term.uppercased(),
                  let latin = term.applyingTransform(.toLatin, reverse: false)?.uppercased(),
                  latin.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else { return nil }
            return (term, latin)
        }
        nameInstrumentals = terms.compactMap { term in
            // Only regular single title-case а-stems. Other declensions need
            // explicit linguistic support; e.g. Маша must not become Машой.
            guard term.count >= 4, Self.isRussianWord(term), term.hasSuffix("а"),
                  term == term.prefix(1).uppercased() + term.dropFirst().lowercased(),
                  let consonant = term.dropLast().last, "бвдзлмнпрстф".contains(consonant) else { return nil }
            return String(term.dropLast()) + "ой"
        }
        let english = terms.filter { $0.unicodeScalars.contains { (65...90).contains($0.value) || (97...122).contains($0.value) } }
        let needed = Set(english.flatMap { Self.parts($0).map { $0.lowercased() } })
        var phones: [String: [String]] = [:]
        for line in pronunciations.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let word = fields.first else { continue }
            let base = String(word.split(separator: "(")[0])
            if needed.contains(base) {
                let spoken = fields.dropFirst().compactMap { Self.arpabet[String($0.filter { !$0.isNumber })] }.joined()
                if !spoken.isEmpty { phones[base, default: []].append(spoken) }
            }
        }
        self.phones = phones
        self.entries = english.map { term in
            let initialism = Self.isInitialism(term)
            var sounds = [Self.sound(term, phones: phones), Self.sound(term, phones: [:])]
            if initialism {
                sounds.append(Self.transliterate(term.lowercased()))
                // Adjacent English letter names can contract in Russian speech:
                // джи + ар → джар. Keep the affricate; жар is not equivalent.
                sounds += sounds.map { $0.replacingOccurrences(of: "джиар", with: "джар") }
            }
            // In Russian, the initial English Y is commonly pronounced both
            // /wai/ and /ai/. Limit this variant to a separate letter in a name.
            if Self.parts(term).first?.uppercased() == "Y" {
                sounds += sounds.filter { $0.hasPrefix("вай") }.map { String($0.dropFirst()) }
            }
            let spelling = initialism && term.count >= 3 ? Self.transliterate(term.lowercased()) : nil
            return Entry(term: term, keys: Set(sounds.map(Self.key).filter { $0.count >= 3 }), initialism: initialism,
                         cyrillicSpelling: spelling)
        }
    }

    func apply(to text: String) -> String {
        let original = RecognitionVocabulary.apply(to: text, vocabulary: vocabulary)
        guard !entries.isEmpty else { return original }
        let ns = original as NSString
        let words = Self.words(original)
        let protected = TranscriptOrthography.literalRanges(in: original)
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < words.count {
            var found: (NSRange, String, Int)?
            for count in stride(from: min(6, words.count - index), through: 1, by: -1) {
                let range = NSRange(location: words[index].range.location,
                    length: NSMaxRange(words[index + count - 1].range) - words[index].range.location)
                guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let source = ns.substring(with: range)
                guard Self.joinable(source) else { continue }
                if count > 1, Self.standaloneWords.contains(words[index].text.lowercased()) || Self.standaloneWords.contains(words[index + count - 1].text.lowercased()) { continue }
                let matches = entries.compactMap { entry -> String? in
                    matched(source, entry: entry).map { $0.prefix + entry.term + $0.suffix }
                }
                if Set(matches).count == 1, let replacement = matches.first {
                    found = (range, replacement, count); break
                }
            }
            if let found { replacements.append((found.0, found.1)); index += found.2 }
            else { index += 1 }
        }
        let output = NSMutableString(string: original)
        for (range, replacement) in replacements.reversed() { output.replaceCharacters(in: range, with: replacement) }
        return output as String
    }

    func needsNumericEndingCheck(in text: String) -> Bool {
        RussianRecognition.needsNumericEndingCheck(in: text, vocabulary: vocabulary)
    }

    /// Near misses are suggestions for a fresh audio decode, never direct text
    /// replacements. Short English initialisms stay unchanged; a unique explicit
    /// Cyrillic initialism can supply a cross-script audio hypothesis.
    /// Numeric near misses suggest a spelling only; the fresh decode must
    /// independently contain that exact form at the same local anchors.
    func numericRepairContext(in original: String) -> String? {
        RussianRecognition.numericRepairContext(in: original, vocabulary: vocabulary, expected: numericRepairForm)
    }

    func restoringNumericName(original: String, candidate: String) -> String? {
        RussianRecognition.restoringNumericName(original: original, candidate: apply(to: candidate),
                                                  vocabulary: vocabulary, expected: numericRepairForm)
    }

    private func numericRepairForm(_ source: String) -> String? {
        guard Self.isRussianWord(source), apply(to: source) == source,
              !terms.contains(where: { RecognitionVocabulary.contains($0, in: source) }),
              let suggestion = numericSuggestion(source), promptHypothesis(source) == suggestion,
              let apostrophe = suggestion.firstIndex(of: "'") else { return nil }
        let term = String(suggestion[..<apostrophe])
        let ending = String(suggestion[suggestion.index(after: apostrophe)...]).lowercased()
        let acronym = String(term.drop(while: \.isNumber)).lowercased().replacingOccurrences(of: "ё", with: "е")
        let lower = source.lowercased().replacingOccurrences(of: "ё", with: "е")
        guard !ending.isEmpty, lower.hasSuffix(acronym + ending),
              !terms.contains(where: { $0 != term && RecognitionVocabulary.contains($0, in: suggestion) }) else { return nil }
        return suggestion
    }

    func promptHypothesis(_ text: String) -> String {
        promptResult(text).text
    }

    /// A compact glossary for a fresh decode, containing only terms observed in
    /// either hypothesis or supported by the existing conservative hint path.
    func relevantTerms(in texts: [String]) -> String {
        let observed = texts.flatMap { [$0, promptHypothesis($0)] }
        var seen: Set<String> = []
        var relevant: [String] = []
        for term in terms where observed.contains(where: { RecognitionVocabulary.contains(term, in: $0) }) {
            if seen.insert(term.lowercased()).inserted { relevant.append(term) }
            if relevant.count == 8 { break }
        }
        return relevant.joined(separator: ", ")
    }

    /// These conservative hints must not authorize a rewrite of an entire turn.
    /// Report the actual prompt traversal, including normalization and competing
    /// phrase matches, so callers can require a localized audio-confirmed repair.
    func hasCyrillicHints(in text: String) -> Bool {
        promptResult(text).hasCyrillicHints
    }

    /// Give the audio decoder only explicit name phrases independently heard by
    /// the verifier. Its unrelated wording must not outweigh the original audio.
    func focusedNameHypothesis(original: String, corroboration: String) -> String? {
        var seen: Set<String> = []
        let phrases = nameInstrumentals.compactMap { name -> String? in
            let pattern = #"(?<![\p{L}\p{N}])с\s+"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            let options: String.CompareOptions = [.regularExpression, .caseInsensitive]
            guard corroboration.range(of: pattern, options: options) != nil,
                  original.range(of: pattern, options: options) == nil,
                  seen.insert(name).inserted else { return nil }
            return "с " + name
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: ", ")
    }

    func promptResult(_ text: String) -> (text: String, hasCyrillicHints: Bool) {
        let normalized = apply(to: text)
        let ns = normalized as NSString
        let words = Self.words(normalized)
        let protected = TranscriptOrthography.literalRanges(in: normalized)
        var replacements: [(NSRange, String)] = []
        var hasCyrillicHints = false
        var index = 0
        while index < words.count {
            var found: (NSRange, String, Int)?
            for count in stride(from: min(3, words.count - index), through: 1, by: -1) {
                let range = NSRange(location: words[index].range.location,
                    length: NSMaxRange(words[index + count - 1].range) - words[index].range.location)
                guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) else { continue }
                let source = ns.substring(with: range)
                if count == 1, let suggestion = cyrillicSuggestion(source) {
                    hasCyrillicHints = true
                    found = (range, suggestion, count); break
                }
                guard source.filter(\.isLetter).count >= 6 else { continue }
                if source.contains("&") {
                    guard count > 1, source.allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace || "-'’&".contains($0) }),
                          let span = Range(range, in: normalized) else { continue }
                    let surrounding = String(normalized[..<span.lowerBound].reversed().prefix { !$0.isWhitespace }.reversed())
                        + source + String(normalized[span.upperBound...].prefix { !$0.isWhitespace })
                    guard !surrounding.contains(where: { ":/\\@=_`\"«»“”".contains($0) }) else { continue }
                } else if !Self.joinable(source) { continue }
                if count > 1, Self.standaloneWords.contains(words[index].text.lowercased()) || Self.standaloneWords.contains(words[index + count - 1].text.lowercased()) { continue }
                if let suggestion = suggestion(source) { found = (range, suggestion, count); break }
            }
            if let found { replacements.append((found.0, found.1)); index += found.2 }
            else { index += 1 }
        }
        let output = NSMutableString(string: normalized)
        for (range, replacement) in replacements.reversed() { output.replaceCharacters(in: range, with: replacement) }
        return (output as String, hasCyrillicHints)
    }

    private func cyrillicSuggestion(_ source: String) -> String? {
        guard !terms.contains(where: { RecognitionVocabulary.contains($0, in: source) }) else { return nil }
        if let numeric = numericSuggestion(source) { return numeric }
        if (3...8).contains(source.count), source.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) {
            // An exact transliterated spelling is already plausible. Never
            // trade it for a neighboring dictionary acronym.
            guard !cyrillicInitialisms.contains(where: { $0.latin == source }) else { return nil }
            let matches = Set(cyrillicInitialisms.filter {
                (source.count >= 4 && $0.latin.count == source.count && Self.distance(source, $0.latin) == 1)
                    || Self.omitsRepeatedLetter(source, from: $0.latin)
            }.map(\.term))
            return matches.count == 1 ? matches.first : nil
        }
        let lower = source.lowercased()
        guard lower.hasPrefix("с"), Self.isRussianWord(source) else { return nil }
        let form = String(lower.dropFirst())
        // Only repair a fused preposition before an inflected known name.
        // A correctly spelled competing name always defeats a fuzzy match.
        guard form.count >= 5, !nameInstrumentals.contains(where: { $0.lowercased() == form }) else { return nil }
        let matches = Set(nameInstrumentals.filter {
            $0.lowercased().first == form.first && Self.distance(form, $0.lowercased()) == 1
        })
        return matches.count == 1 ? matches.first.map { "с " + $0 } : nil
    }

    /// A hint requires a whole fused numeral, acronym and recognized ending.
    /// Permit a miss in either the numeral or the acronym, never both.
    private func numericSuggestion(_ source: String) -> String? {
        let lower = source.lowercased().replacingOccurrences(of: "ё", with: "е")
        guard Self.isRussianWord(lower) else { return nil }
        var candidates: [(term: String, ending: String, distance: Int)] = []
        for term in terms {
            guard let forms = RecognitionVocabulary.numericForms(for: term) else { continue }
            let acronym = String(term.drop(while: \.isNumber)).lowercased().replacingOccurrences(of: "ё", with: "е")
            for ending in AbbreviationFamilies.caseEndings where lower.hasSuffix(ending) {
                let stem = String(lower.dropLast(ending.count))
                guard stem.count >= acronym.count + 2 else { continue }
                let prefix = String(stem.dropLast(acronym.count))
                let actualAcronym = String(stem.suffix(acronym.count))
                let acronymDistance = Self.distance(actualAcronym, acronym)
                for form in forms {
                    let numeral = form.replacingOccurrences(of: "ё", with: "е")
                    guard prefix.first == numeral.first else { continue }
                    let numeralDistance = Self.distance(prefix, numeral)
                    guard (acronymDistance == 0 && numeralDistance <= 2)
                        || (numeralDistance == 0 && acronymDistance <= 1) else { continue }
                    let distance = numeralDistance + acronymDistance
                    if distance > 0 { candidates.append((term, ending, distance)) }
                }
            }
        }
        guard let best = candidates.map(\.distance).min() else { return nil }
        let winners = candidates.filter { $0.distance == best }
        let replacements = Set(winners.map { $0.term + "'" + $0.ending })
        return replacements.count == 1 ? replacements.first : nil
    }

    private static func isRussianWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            (0x410...0x44f).contains($0.value) || $0.value == 0x401 || $0.value == 0x451
        }
    }

    private static func omitsRepeatedLetter(_ source: String, from target: String) -> Bool {
        let letters = Array(target)
        guard letters.count == source.count + 1 else { return false }
        for index in 1..<letters.count {
            guard letters[index] == letters[index - 1] else { continue }
            let candidate = String(letters[..<index]) + String(letters[(index + 1)...])
            if candidate == source { return true }
        }
        return false
    }

    private func suggestion(_ source: String) -> String? {
        guard !terms.contains(where: { RecognitionVocabulary.contains($0, in: source) }) else { return nil }
        var forms = [(source, "")]
        if source.lowercased().hasPrefix("с") { forms.append((String(source.dropFirst()), "с ")) }
        let completeForms = forms
        for (form, prefix) in completeForms {
            for ending in AbbreviationFamilies.caseEndings where form.lowercased().hasSuffix(ending) {
                let stem = String(form.dropLast(ending.count))
                if (stem.split(whereSeparator: \.isWhitespace).last?.count ?? 0) >= 3 { forms.append((stem, prefix)) }
            }
        }
        var candidates: [(term: String, replacement: String, distance: Int)] = []
        for entry in entries where !entry.initialism {
            if source.contains("&"), entry.term.split(whereSeparator: \.isWhitespace).count < 2 { continue }
            for (form, prefix) in forms {
                let key = Self.key(Self.sound(form, phones: phones))
                for target in entry.keys where min(key.count, target.count) >= 5 && key.first == target.first {
                    let distance = Self.distance(key, target)
                    let latin = source.filter(\.isLetter).unicodeScalars.allSatisfy { (65...90).contains($0.value) || (97...122).contains($0.value) }
                    let limit = latin && min(key.count, target.count) >= 6 ? 2 : 1
                    if distance <= limit { candidates.append((entry.term, prefix + entry.term, distance)) }
                }
            }
        }
        guard let best = candidates.map(\.distance).min(), best > 0 || source.contains("&") else { return nil }
        let winners = candidates.filter { $0.distance == best }
        return Set(winners.map(\.term)).count == 1 ? winners.first?.replacement : nil
    }

    private func matched(_ source: String, entry: Entry) -> (prefix: String, suffix: String)? {
        var variants = [(source, "")]
        // A preposition sometimes sticks to a following foreign name. Only
        // split с when a complete dictionary pronunciation follows it.
        if source.lowercased().hasPrefix("с"), source.count > 6 { variants.append((String(source.dropFirst()), "с ")) }
        // A fused с + English I/Y can be written as ци/цы by ASR. The complete
        // remaining name must still match; ordinary цикл/циклон do not qualify.
        if ["I", "Y"].contains(Self.parts(entry.term).first?.uppercased() ?? ""),
           source.count > 6, ["ци", "цы"].contains(String(source.lowercased().prefix(2))) {
            variants.append(("ай" + source.dropFirst(2), "с "))
        }
        for (variant, prefix) in variants {
            let lower = variant.lowercased()
            var stems: [(text: String, phoneticSuffix: String, literalSuffix: String)] = [(variant, "", "")]
            for ending in AbbreviationFamilies.caseEndings where lower.hasSuffix(ending) {
                stems.append((String(variant.dropLast(ending.count)), entry.initialism ? "'" + ending : "", "'" + ending))
            }
            if entry.initialism {
                for ending in AbbreviationFamilies.derivedEndings where lower.hasSuffix(ending) {
                    stems.append((String(variant.dropLast(ending.count)), "'" + ending, "'" + ending))
                }
            }
            for (stem, phoneticSuffix, literalSuffix) in stems {
                guard stem == stem.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                // A separately supplied Russian name takes precedence over an
                // acronym pronunciation, including its recognized case ending.
                let literal = stem.trimmingCharacters(in: CharacterSet(charactersIn: "'’")).lowercased()
                if literal != entry.term.lowercased(), explicitTerms.contains(literal) { return nil }
                // Exact letters retain repetitions that a phonetic key collapses
                // (LLM is not LM or LMM). Preserve an ending attached to that
                // explicit spelling without interpreting a Latin M as Russian ем.
                if entry.initialism, literal == entry.term.lowercased() || literal == entry.cyrillicSpelling {
                    return (prefix, literalSuffix)
                }
                let key = Self.key(Self.sound(stem, phones: phones))
                if entry.keys.contains(key) { return (prefix, phoneticSuffix) }
            }
        }
        return nil
    }

    private static let letterNames: [Character: String] = [
        "a":"эй", "b":"би", "c":"си", "d":"ди", "e":"и", "f":"эф", "g":"джи", "h":"эйч", "i":"ай",
        "j":"джей", "k":"кей", "l":"эл", "m":"эм", "n":"эн", "o":"оу", "p":"пи", "q":"кью", "r":"ар",
        "s":"эс", "t":"ти", "u":"ю", "v":"ви", "w":"даблъю", "x":"экс", "y":"вай", "z":"зед",
        "0":"зироу", "1":"уан", "2":"ту", "3":"три", "4":"фор", "5":"файв", "6":"сикс", "7":"севен", "8":"эйт", "9":"найн"
    ]
    private static let arpabet = [
        "AA":"а", "AE":"э", "AH":"а", "AO":"о", "AW":"ау", "AY":"ай", "EH":"э", "ER":"ер", "EY":"эй",
        "IH":"и", "IY":"и", "OW":"оу", "OY":"ой", "UH":"у", "UW":"у", "B":"б", "CH":"ч", "D":"д",
        "DH":"з", "F":"ф", "G":"г", "HH":"х", "JH":"дж", "K":"к", "L":"л", "M":"м", "N":"н", "NG":"нг",
        "P":"п", "R":"р", "S":"с", "SH":"ш", "T":"т", "TH":"т", "V":"в", "W":"в", "Y":"й", "Z":"з", "ZH":"ж"
    ]
    private static func isInitialism(_ text: String) -> Bool {
        (2...6).contains(text.count) && text == text.uppercased() && text != text.lowercased()
            && text.allSatisfy { letterNames[$0.lowercased().first!] != nil }
    }
    private static let partExpression = try! NSRegularExpression(
        pattern: #"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]|[\p{L}&&[^A-Za-z]]+"#)
    private static func parts(_ text: String) -> [String] {
        let ns = text as NSString
        return partExpression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    private static func sound(_ text: String, phones: [String: [String]]) -> String {
        parts(text).map { part in
            let lower = part.lowercased()
            if part.count == 1, let sound = letterNames[lower.first!] { return sound }
            if isInitialism(part) { return lower.compactMap { letterNames[$0] }.joined() }
            if let spoken = phones[lower]?.first { return spoken }
            return transliterate(lower)
        }.joined()
    }
    private static func transliterate(_ text: String) -> String {
        var value = text
        for (from, to) in [("tion", "шн"), ("sh", "ш"), ("ch", "ч"), ("ph", "ф"), ("th", "т"), ("qu", "к"),
                           ("ce", "се"), ("ci", "си"), ("cy", "си"), ("ck", "к")] {
            value = value.replacingOccurrences(of: from, with: to)
        }
        if value.hasSuffix("e") || value.hasSuffix("е"), value.unicodeScalars.contains(where: { (97...122).contains($0.value) }) { value.removeLast() }
        value = value.replacingOccurrences(of: "x", with: "кс")
        let letters = Dictionary(uniqueKeysWithValues: zip(Array("abcdefghijklmnopqrstuvwyz"), Array("абкдефгхийклмнопкрстуввиз")))
        return value.map { String(letters[$0] ?? $0) }.joined()
    }
    private static func key(_ sound: String) -> String {
        var value = sound.lowercased().replacingOccurrences(of: "ц", with: "тс")
        value = value.replacingOccurrences(of: "нтс", with: "нс")
        var result = "", previousVowel = false
        for character in value {
            if "ьъй'’ -".contains(character) { continue }
            let vowel = "аоыуэеиёюя".contains(character)
            if vowel {
                if !previousVowel { result += "эеиё".contains(character) ? "E" : "A" }
            } else {
                let normalized: Character = character == "з" ? "с" : character
                if result.last != normalized { result.append(normalized) }
            }
            previousVowel = vowel
        }
        return result
    }
    private static func words(_ text: String) -> [Word] {
        let regex = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#)
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Word(text: ns.substring(with: $0.range), range: $0.range) }
    }
    private static func joinable(_ source: String) -> Bool {
        source.allSatisfy { $0.isLetter || $0.isNumber || $0.isWhitespace || "-'’".contains($0) }
    }
    private static func distance(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        var row = Array(0...right.count)
        for (i, character) in left.enumerated() {
            var next = [i + 1]
            for (j, other) in right.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (character == other ? 0 : 1))) }
            row = next
        }
        return row.last!
    }
}
