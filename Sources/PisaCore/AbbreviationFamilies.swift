import Foundation

/// Shared spelling families. A suffix is evidence already present in a token,
/// never a grammatical prediction. Explicit dictionary entries win over aliases.
struct AbbreviationFamilies {
    struct Form: Equatable, Sendable {
        let base: String
        let ending: String
        var text: String {
            guard !ending.isEmpty else { return base }
            return base + "'" + ending
        }
    }

    static let caseEndings = ["ами", "ями", "ого", "ому", "ов", "ом", "ем", "ам", "ах", "ям", "ях", "а", "у", "е", "ы", "и"]
    private static let hardAdjectiveEndings = ["ый", "ая", "ое", "ые", "ого", "ой", "ому", "ым", "ую", "ою", "ом", "ых", "ыми"]
    private static let velarAdjectiveEndings = ["ий", "ая", "ое", "ие", "ого", "ой", "ому", "им", "ую", "ою", "ом", "их", "ими"]
    static let adjectiveSuffixes = ["ов", "ев"].flatMap { stem in hardAdjectiveEndings.map { stem + $0 } }
        + ["овск", "евск", "ск"].flatMap { stem in velarAdjectiveEndings.map { stem + $0 } }
    static let diminutiveEndings = ["ками", "кой", "кою", "ках", "кам", "ка", "ку", "ке", "ки", "ок",
                                    "шками", "шкой", "шкою", "шкам", "шках", "шек", "шка", "шки", "шку", "шке"]
    static let derivedEndings = diminutiveEndings
        + ["ник", "шник"].flatMap { stem in ["", "а", "у", "ом", "е", "и", "ов", "ам", "ами", "ах"].map { stem + $0 } }
        + ["ниц", "шниц"].flatMap { stem in ["", "а", "ы", "е", "у", "ей", "ею", "ам", "ами", "ах"].map { stem + $0 } }
        + adjectiveSuffixes
    static let endings = (caseEndings + derivedEndings).sorted { $0.count > $1.count }
    static let promptEndings = ["а", "ом", "е", "у"]
    private static let latinEndings = ["a": "а", "u": "у", "om": "ом", "e": "е"]
    static let hyphens = "-‐‑"
    private static let apostrophes = "'’"
    private static let derivedEndingSet = Set(derivedEndings)
    private static let derivedEndingsByLastLetter = Dictionary(
        grouping: derivedEndings.sorted { $0.count > $1.count }, by: \.last
    )
    private static let endingSet = Set(endings)
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’\-‐‑][\p{L}\p{N}]+)*"#)
    private static let russianFunctionWords: Set<String> = [
        "а", "без", "близ", "будто", "бы", "в", "вблизи", "ввиду", "вдоль",
        "взамен", "вместо", "вне", "внутри", "во", "вокруг", "вопреки",
        "вроде", "вслед", "да", "дабы", "даже", "для", "до", "едва", "если",
        "же", "за", "зато", "и", "ибо", "из", "или", "как", "к", "ко",
        "кроме", "ли", "либо", "лишь", "меж", "между", "мимо", "на", "над",
        "не", "ни", "но", "о", "об", "обо", "около", "от", "ото", "перед",
        "по", "под", "подо", "пока", "помимо", "после", "при", "про", "против",
        "пусть", "ради", "разве", "с", "сверх", "сквозь", "словно", "со",
        "согласно", "среди", "так", "типа", "то", "у", "уж", "хоть", "хотя",
        "через", "чем", "что", "чтобы"
    ]
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

    static func isRussianFunctionWord(_ token: String) -> Bool {
        russianFunctionWords.contains(token.lowercased())
    }

    /// A known base such as ПО needs explicit acronym casing because
    /// its lowercase and sentence-case spellings are ordinary Russian.
    private static func matchesBaseCasing(_ source: String, as base: String) -> Bool {
        source == base || !isRussianFunctionWord(base)
    }

    static func ending(_ raw: String, numeric: Bool, separator: Character? = nil) -> String? {
        let lower = raw.lowercased()
        if let separator, hyphens.contains(separator) { return derivedEndingSet.contains(lower) ? lower : nil }
        if endingSet.contains(lower) { return lower }
        return numeric ? latinEndings[lower] : nil
    }

    static let hyphenatedEndingPattern = "[-‐‑](?:" + derivedEndings.joined(separator: "|") + ")"
    private static let russianWrittenEndings = makeWrittenEndingPattern(endings)
    private static let numericWrittenEndings = makeWrittenEndingPattern(
        (endings + Array(latinEndings.keys)).sorted { $0.count > $1.count }
    )

    static func writtenEndingPattern(numeric: Bool) -> String {
        numeric ? numericWrittenEndings : russianWrittenEndings
    }

    private static func makeWrittenEndingPattern(_ endings: [String]) -> String {
        "(?:['’]?(?:" + endings.joined(separator: "|") + ")|" + hyphenatedEndingPattern + ")"
    }

    static func matchingDerivedEndings(in word: String) -> [String] {
        (derivedEndingsByLastLetter[word.last] ?? []).filter { word.hasSuffix($0) }
    }

    /// Without a known base, infer only an uppercase abbreviation followed by
    /// an explicit separator or a lowercase Russian ending. All-uppercase
    /// spellings such as 2GISA may themselves be independent abbreviations.
    static func inferred(_ token: String) -> Form? {
        if let separator = token.firstIndex(where: { apostrophes.contains($0) || hyphens.contains($0) }) {
            let base = String(token[..<separator])
            let tail = String(token[token.index(after: separator)...])
            guard isBase(base), let ending = ending(tail, numeric: base.first?.isNumber == true,
                                                    separator: token[separator]) else { return nil }
            return Form(base: base, ending: ending)
        }
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

    /// Shape check for an independently corroborated numeric abbreviation.
    /// The digit and any heard ending must survive the missing letter.
    static func omitsNumericAcronymLetter(_ source: String, from form: Form) -> Bool {
        let digits = form.base.prefix(while: \.isNumber)
        guard !digits.isEmpty, isBase(form.base), form.base.count >= digits.count + 3 else { return false }
        return aliases(for: form.base).contains { alias in
            let letters = Array(alias)
            return letters.indices.dropFirst(digits.count).contains { index in
                let shortened = String(letters[..<index] + letters[(index + 1)...])
                return parse(source, as: shortened, aliases: [shortened])?.ending == form.ending
            }
        }
    }

    private static func parse(_ token: String, as base: String, aliases: [String]) -> Form? {
        for alias in aliases {
            guard token.count >= alias.count else { continue }
            let prefix = String(token.prefix(alias.count))
            guard key(prefix) == key(alias), matchesBaseCasing(prefix, as: alias) else { continue }
            var tail = String(token.dropFirst(alias.count))
            if tail.isEmpty { return Form(base: base, ending: "") }
            let separator = tail.first.flatMap { apostrophes.contains($0) || hyphens.contains($0) ? $0 : nil }
            if separator != nil { tail.removeFirst() }
            guard let ending = ending(tail, numeric: base.first?.isNumber == true, separator: separator) else { continue }
            // A lowercase acronym prefix can coincide with an ordinary word,
            // e.g. a saved СОТ in «сотниками». A written separator or uppercase
            // base establishes where the derivational suffix starts.
            if separator == nil, prefix != prefix.uppercased(), derivedEndingSet.contains(ending),
               TranscriptTerms.isCommonRussianWord(key(token).replacingOccurrences(of: "ё", with: "е")) { continue }
            return Form(base: base, ending: ending)
        }
        return nil
    }

    func isExplicit(_ token: String) -> Bool { explicit[Self.key(token)] != nil }

    func hasKnownBase(_ token: String) -> Bool {
        entries.contains { Self.parse(token, as: $0.base, aliases: $0.aliases) != nil }
    }

    func known(_ token: String) -> Form? {
        if let exact = explicit[Self.key(token)] {
            guard Self.isBase(exact), Self.matchesBaseCasing(token, as: exact) else { return nil }
            return Form(base: exact, ending: "")
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

    func normalize(in text: String, includeInferred: Bool = false, protecting ranges: [NSRange] = []) -> String {
        let output = NSMutableString(string: text)
        let protected = TranscriptOrthography.literalRanges(in: text) + ranges
        for match in Self.token.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text),
                  !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { continue }
            let token = String(text[range])
            let spelling = includeInferred ? form(token) : known(token)
            guard let replacement = spelling?.text, replacement != token else { continue }
            // Do not repair a fragment of an identifier, address or hyphenated name.
            let before = text[..<range.lowerBound].last
            let after = text[range.upperBound...].first
            let attached = "_/@\\-‐‑"
            guard before.map({ attached.contains($0) }) != true,
                  after.map({ attached.contains($0) }) != true else { continue }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        return output as String
    }
}
