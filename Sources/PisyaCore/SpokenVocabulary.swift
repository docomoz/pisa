import Foundation

/// Prepared once per user vocabulary. Only explicit dictionary entries are
/// eligible; pronunciations are derived locally, never saved as extra entries.
struct SpokenVocabulary {
    private struct Entry {
        var term: String
        var keys: Set<String>
        var initialism: Bool
    }
    private struct Word { var text: String; var range: NSRange }
    private let vocabulary: String
    private let entries: [Entry]
    private let phones: [String: [String]]
    private static let standaloneWords: Set<String> = ["в", "во", "с", "со", "к", "и", "а", "у", "о", "на", "из", "от", "я", "ты", "мы", "он", "она", "они", "вы", "да", "но", "не", "же", "ли", "бы", "для", "по", "за"]

    init(_ vocabulary: String, pronunciations: String = "") {
        self.vocabulary = vocabulary
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
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
            if initialism { sounds.append(Self.transliterate(term.lowercased())) }
            // In Russian, the initial English Y is commonly pronounced both
            // /wai/ and /ai/. Limit this variant to a separate letter in a name.
            if Self.parts(term).first?.uppercased() == "Y" {
                sounds += sounds.filter { $0.hasPrefix("вай") }.map { String($0.dropFirst()) }
            }
            return Entry(term: term, keys: Set(sounds.map(Self.key).filter { $0.count >= 3 }), initialism: initialism)
        }
    }

    func apply(to text: String) -> String {
        let original = RecognitionVocabulary.apply(to: text, vocabulary: vocabulary)
        guard !entries.isEmpty else { return original }
        let ns = original as NSString
        let words = Self.words(original)
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < words.count {
            var found: (NSRange, String, Int)?
            for count in stride(from: min(6, words.count - index), through: 1, by: -1) {
                let range = NSRange(location: words[index].range.location,
                    length: NSMaxRange(words[index + count - 1].range) - words[index].range.location)
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

    /// Near misses are suggestions for a fresh audio decode, never direct text
    /// replacements. Short initialisms are excluded: BFC may really mean BFC.
    func promptHypothesis(_ text: String) -> String {
        let normalized = apply(to: text)
        let ns = normalized as NSString
        let words = Self.words(normalized)
        var replacements: [(NSRange, String)] = []
        var index = 0
        while index < words.count {
            var found: (NSRange, String, Int)?
            for count in stride(from: min(3, words.count - index), through: 1, by: -1) {
                let range = NSRange(location: words[index].range.location,
                    length: NSMaxRange(words[index + count - 1].range) - words[index].range.location)
                let source = ns.substring(with: range)
                guard source.filter(\.isLetter).count >= 6, Self.joinable(source) else { continue }
                if count > 1, Self.standaloneWords.contains(words[index].text.lowercased()) || Self.standaloneWords.contains(words[index + count - 1].text.lowercased()) { continue }
                if let suggestion = suggestion(source) { found = (range, suggestion, count); break }
            }
            if let found { replacements.append((found.0, found.1)); index += found.2 }
            else { index += 1 }
        }
        let output = NSMutableString(string: normalized)
        for (range, replacement) in replacements.reversed() { output.replaceCharacters(in: range, with: replacement) }
        return output as String
    }

    private func suggestion(_ source: String) -> String? {
        var forms = [(source, "")]
        if source.lowercased().hasPrefix("с") { forms.append((String(source.dropFirst()), "с ")) }
        var candidates: [(term: String, replacement: String, distance: Int)] = []
        for entry in entries where !entry.initialism {
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
        guard let best = candidates.map(\.distance).min(), best > 0 else { return nil }
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
            var stems: [(String, String)] = [(variant, "")]
            for ending in ["ами", "ями", "ого", "ому", "ов", "ом", "ем", "ам", "ах", "ям", "ях", "а", "у", "е", "ы", "и"] where lower.hasSuffix(ending) {
                stems.append((String(variant.dropLast(ending.count)), ""))
            }
            if entry.initialism {
                for ending in ["ками", "кой", "ках", "кам", "ка", "ку", "ке", "ки", "ок"] where lower.hasSuffix(ending) {
                    stems.append((String(variant.dropLast(ending.count)), "'" + ending))
                }
            }
            for (stem, suffix) in stems {
                guard stem == stem.trimmingCharacters(in: .whitespacesAndNewlines) else { continue }
                let key = Self.key(Self.sound(stem, phones: phones))
                if entry.keys.contains(key) { return (prefix, suffix) }
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
    private static func parts(_ text: String) -> [String] {
        let pattern = #"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]|[\p{L}&&[^A-Za-z]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
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
