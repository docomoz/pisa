import Foundation

/// Shared spelling families. A suffix is evidence already present in a token,
/// never a grammatical prediction. Explicit dictionary entries win over aliases.
struct AbbreviationFamilies {
    struct Form: Equatable, Sendable {
        let base: String
        let ending: String
        var text: String {
            guard !ending.isEmpty else { return base }
            let apostrophe = base.first?.isNumber == true || base.contains { $0.isASCII && $0.isLetter }
            return base + (apostrophe ? "'" : "") + ending
        }
    }

    static let caseEndings = ["ами", "ями", "ого", "ому", "ов", "ом", "ем", "ам", "ах", "ям", "ях", "а", "у", "е", "ы", "и"]
    static let derivedEndings = ["ками", "кой", "ках", "кам", "ка", "ку", "ке", "ки", "ок"]
    static let endings = (caseEndings + derivedEndings).sorted { $0.count > $1.count }
    static let promptEndings = ["а", "ом", "е", "у"]
    private static let latinEndings = ["a": "а", "u": "у", "om": "ом", "e": "е"]
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private struct Entry {
        let base: String
        let aliases: [String]
    }
    private let entries: [Entry]
    private let explicit: [String: String]

    init(_ vocabulary: String) {
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        entries = terms.filter(Self.isBase).map { Entry(base: $0, aliases: Self.aliases(for: $0)) }
        explicit = Dictionary(terms.map { (Self.key($0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func isBase(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        return (2...12).contains(letters.count) && term.count <= 20 && term.allSatisfy { character in
            (character.isASCII && character.isNumber) || (character.isLetter && character.isUppercase && character.unicodeScalars.allSatisfy {
                (65...90).contains($0.value) || (0x410...0x42f).contains($0.value) || $0.value == 0x401
            })
        }
    }

    static func key(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
    }

    static func ending(_ raw: String, numeric: Bool) -> String? {
        let lower = raw.lowercased()
        if endings.contains(lower) { return lower }
        return numeric ? latinEndings[lower] : nil
    }

    static func endingPattern(numeric: Bool) -> String {
        (endings + (numeric ? Array(latinEndings.keys) : [])).sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    /// Without a known base, infer only an uppercase abbreviation followed by
    /// an explicit apostrophe or a lowercase Russian ending. All-uppercase
    /// spellings such as 2GISA may themselves be independent abbreviations.
    static func inferred(_ token: String) -> Form? {
        let parts = token.replacingOccurrences(of: "’", with: "'").components(separatedBy: "'")
        if parts.count == 2, isBase(parts[0]),
           let ending = ending(parts[1], numeric: parts[0].first?.isNumber == true) {
            return Form(base: parts[0], ending: ending)
        }
        guard parts.count == 1 else { return nil }
        if isBase(token) { return Form(base: token, ending: "") }
        for suffix in endings where token.hasSuffix(suffix) {
            let base = String(token.dropLast(suffix.count))
            if isBase(base) { return Form(base: base, ending: suffix) }
        }
        return nil
    }

    static func aliases(for base: String) -> [String] {
        guard base.first?.isNumber == true else { return [base] }
        var aliases = [base]
        if let latin = base.applyingTransform(.toLatin, reverse: false)?.uppercased() { aliases.append(latin) }
        // Letter-for-letter Russian spelling is useful only for a numeric
        // acronym. It is not a general phonetic equivalence for foreign names.
        let russian: [Character: Character] = ["A":"А", "B":"Б", "V":"В", "G":"Г", "D":"Д", "E":"Е", "Z":"З", "I":"И", "K":"К", "L":"Л", "M":"М", "N":"Н", "O":"О", "P":"П", "R":"Р", "S":"С", "T":"Т", "U":"У", "F":"Ф"]
        if base.drop(while: \.isNumber).allSatisfy({ russian[$0] != nil }) {
            aliases.append(String(base.map { russian[$0] ?? $0 }))
        }
        return Array(Set(aliases)).sorted()
    }

    static func parse(_ token: String, as base: String) -> Form? {
        parse(token, as: base, aliases: aliases(for: base))
    }

    private static func parse(_ token: String, as base: String, aliases: [String]) -> Form? {
        for alias in aliases {
            guard token.count >= alias.count else { continue }
            let prefix = String(token.prefix(alias.count))
            guard key(prefix) == key(alias) else { continue }
            var tail = String(token.dropFirst(alias.count))
            if tail.isEmpty { return Form(base: base, ending: "") }
            if tail.first == "'" || tail.first == "’" { tail.removeFirst() }
            if let ending = ending(tail, numeric: base.first?.isNumber == true) {
                return Form(base: base, ending: ending)
            }
        }
        return nil
    }

    func isExplicit(_ token: String) -> Bool { explicit[Self.key(token)] != nil }

    func hasKnownBase(_ token: String) -> Bool {
        entries.contains { Self.parse(token, as: $0.base, aliases: $0.aliases) != nil }
    }

    func known(_ token: String) -> Form? {
        if let exact = explicit[Self.key(token)] {
            return Self.isBase(exact) ? Form(base: exact, ending: "") : nil
        }
        let matches = entries.compactMap { Self.parse(token, as: $0.base, aliases: $0.aliases) }
        guard Set(matches.map { Self.key($0.base) }).count == 1 else { return nil }
        return matches.first
    }

    func form(_ token: String) -> Form? {
        if let known = known(token) { return known }
        // An explicit full form or competing aliases must not be regrouped.
        guard !isExplicit(token), !hasKnownBase(token) else { return nil }
        return Self.inferred(token)
    }

    func normalize(in text: String) -> String {
        let output = NSMutableString(string: text)
        let protected = TranscriptOrthography.literalRanges(in: text)
        for match in Self.token.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let form = known(String(text[range])) else { continue }
            // Do not repair a fragment of an identifier, address or hyphenated name.
            let before = text[..<range.lowerBound].last
            let after = text[range.upperBound...].first
            let attached = "_/@\\-‐‑"
            guard before.map({ attached.contains($0) }) != true,
                  after.map({ attached.contains($0) }) != true else { continue }
            output.replaceCharacters(in: match.range, with: form.text)
        }
        return output as String
    }
}
