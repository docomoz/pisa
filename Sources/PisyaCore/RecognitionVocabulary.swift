import Foundation

/// Render explicitly supplied dictionary entries consistently. This is spelling
/// normalization, not fuzzy replacement of names inferred from transcript text.
enum RecognitionVocabulary {
    static func apply(to text: String, vocabulary: String) -> String {
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        let families = AbbreviationFamilies(vocabulary)
        var result = families.normalize(in: text)
        for term in terms {
            if AbbreviationFamilies.isBase(term), numericForms(for: term) == nil { continue }
            let digits = String(term.prefix(while: \.isNumber))
            var pattern = term.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
            var numericAcronym = false
            // A numeric acronym can be spoken with a Russian number and case
            // ending. Derive the forms from the user's entry (e.g. 7АБВ).
            if let forms = numericForms(for: term) {
                let stems = AbbreviationFamilies.aliases(for: term).map { String($0.dropFirst(digits.count)) }
                    .map(NSRegularExpression.escapedPattern).joined(separator: "|")
                // ASR can merge the numeral with the name and spell an unstressed
                // а/о differently. Restrict this equivalence to the known numeral
                // prefix of an explicit dictionary acronym, not arbitrary words.
                let spoken = forms.map { form in
                    form.map { "ао".contains($0) ? "[ао]" : ($0 == "ё" || $0 == "е" ? "[её]" : NSRegularExpression.escapedPattern(for: String($0))) }.joined()
                }.joined(separator: "|")
                pattern = "(?:\(NSRegularExpression.escapedPattern(for: digits))|\(spoken))[\\s-]*(\(stems))(?:['’]?(\(AbbreviationFamilies.endingPattern(numeric: true))))?"
                numericAcronym = true
            }
            guard let expression = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + pattern + #")(?![\p{L}\p{N}])"#, options: [.caseInsensitive]) else { continue }
            let protected = TranscriptOrthography.literalRanges(in: result)
            if numericAcronym {
                let ns = result as NSString, output = NSMutableString(string: result)
                for match in expression.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
                where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    let source = ns.substring(with: match.range)
                    guard !families.isExplicit(source) || AbbreviationFamilies.key(source) == AbbreviationFamilies.key(term) else { continue }
                    let range = match.range(at: 2)
                    let raw = range.location == NSNotFound ? "" : ns.substring(with: range).lowercased()
                    let ending = AbbreviationFamilies.ending(raw, numeric: true) ?? ""
                    let written = digits + ns.substring(with: match.range(at: 1)) + (ending.isEmpty ? "" : "'" + ending)
                    guard families.known(written)?.base == term else { continue }
                    output.replaceCharacters(in: match.range, with: term + (ending.isEmpty ? "" : "'" + ending))
                }
                result = output as String
            } else {
                let ns = result as NSString, output = NSMutableString(string: result)
                for match in expression.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
                where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    output.replaceCharacters(in: match.range, with: sentenceCase(term, replacing: match.range, in: result))
                }
                result = output as String
            }
        }
        return normalizeCyrillicSpelling(in: result, terms: terms)
    }

    /// Cardinal numeral forms used as prefixes of an explicit numeric acronym.
    static func numericForms(for term: String) -> [String]? {
        let digits = String(term.prefix(while: \.isNumber))
        let acronym = String(term.dropFirst(digits.count))
        let forms = [
            ["ноль", "нуля", "нулю", "нулём", "нуле"],
            ["один", "одна", "одно", "одного", "одному", "одним", "одной"],
            ["два", "две", "двух", "двум", "двумя", "дву"],
            ["три", "трёх", "трём", "тремя"],
            ["четыре", "четырёх", "четырём", "четырьмя"],
            ["пять", "пяти", "пятью"], ["шесть", "шести", "шестью"],
            ["семь", "семи", "семью"], ["восемь", "восьми", "восемью"],
            ["девять", "девяти", "девятью"], ["десять", "десяти", "десятью"],
            ["одиннадцать", "одиннадцати", "одиннадцатью"], ["двенадцать", "двенадцати", "двенадцатью"],
            ["тринадцать", "тринадцати", "тринадцатью"], ["четырнадцать", "четырнадцати", "четырнадцатью"],
            ["пятнадцать", "пятнадцати", "пятнадцатью"], ["шестнадцать", "шестнадцати", "шестнадцатью"],
            ["семнадцать", "семнадцати", "семнадцатью"], ["восемнадцать", "восемнадцати", "восемнадцатью"],
            ["девятнадцать", "девятнадцати", "девятнадцатью"], ["двадцать", "двадцати", "двадцатью"]
        ]
        guard let number = Int(digits), forms.indices.contains(number), (2...8).contains(acronym.count),
              acronym.allSatisfy(\.isLetter), acronym == acronym.uppercased(), acronym != acronym.lowercased() else { return nil }
        return forms[number]
    }

    private static func normalizeCyrillicSpelling(in text: String, terms: [String]) -> String {
        var result = text
        let separateWords: Set<String> = ["без", "для", "при", "под", "над", "про", "как", "что", "или", "это", "тот", "через", "перед", "между"]
        for term in terms {
            guard let (stem, endings) = cyrillicForm(term) else { continue }
            // Explicit competing spacing, hyphenation or е/ё spellings defeat
            // normalization, including their case endings.
            guard !terms.contains(where: { other in
                other != term && spellingKey(other) == spellingKey(term)
            }) else { continue }
            let letters = Array(stem)
            let splits = letters.count >= 6 && !stem.contains("-") ? (3...(letters.count - 3)).compactMap { index -> String? in
                let left = String(letters[..<index]), right = String(letters[index...])
                guard !separateWords.contains(left.lowercased()), !separateWords.contains(right.lowercased()) else { return nil }
                return spellingPattern(left) + #"(?:\s+|[-‐‑])"# + spellingPattern(right)
            } : []
            // Preserve the ending already present in the audio transcript.
            // Only spacing, hyphenation, ё and dictionary case are normalized.
            let alternatives = [spellingPattern(stem)] + splits
            let pattern = #"(?<![\p{L}\p{N}])(?:"# + alternatives.joined(separator: "|") + ")" + endings + #"(?![\p{L}\p{N}])"#
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = result as NSString
            let output = NSMutableString(string: result)
            let protected = TranscriptOrthography.literalRanges(in: result)
            for match in expression.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed()
            where !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                let ending = match.range(at: 1)
                let suffix = ending.location == NSNotFound ? "" : ns.substring(with: ending).lowercased()
                output.replaceCharacters(in: match.range, with: sentenceCase(stem + suffix, replacing: match.range, in: result))
            }
            result = output as String
        }
        return result
    }

    /// Exact dictionary spelling and regular endings, never a phonetic guess.
    static func contains(_ term: String, in text: String) -> Bool {
        let body: String
        if AbbreviationFamilies.isBase(term) {
            body = "(?:" + AbbreviationFamilies.aliases(for: term).map(NSRegularExpression.escapedPattern).joined(separator: "|")
                + ")(?:['’]?(?:" + AbbreviationFamilies.endingPattern(numeric: term.first?.isNumber == true) + "))?"
        } else if let (stem, endings) = cyrillicForm(term) {
            body = spellingPattern(stem) + endings
        } else {
            body = term.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\s+"#) + #"(?:['’]?(?:ками|кой|ках|кам|ка|ку|ке|ки|ами|ями|ого|ому|ов|ом|ем|ам|ах|ям|ях|а|у|е|ы|и))?"#
        }
        return text.range(of: #"(?<![\p{L}\p{N}])(?:"# + body + #")(?![\p{L}\p{N}])"#,
                          options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func cyrillicForm(_ term: String) -> (String, String)? {
        guard term.count >= 3, term != term.uppercased(), term.unicodeScalars.allSatisfy({
            (0x410...0x44f).contains($0.value) || $0.value == 0x401 || $0.value == 0x451 || $0.value == 45
        }) else { return nil }
        if term.hasSuffix("а") { return (String(term.dropLast()), "(ами|ам|ах|ою|ой|а|ы|и|е|у)") }
        if term.hasSuffix("ь") { return (String(term.dropLast()), "(ями|ям|ях|ем|ей|ь|я|ю|е|и)") }
        return (term, term.last.map { "бвгджзклмнпрстфхцчшщ".contains($0) } == true
                ? #"(ами|ам|ах|ов|ом|а|у|е|ы|и)?"# : "()")
    }

    private static func sentenceCase(_ spelling: String, replacing range: NSRange, in text: String) -> String {
        guard spelling.first?.isLowercase == true, cyrillicForm(spelling) != nil,
              let source = Range(range, in: text), text[source].first?.isUppercase == true else { return spelling }
        let line = text[..<source.lowerBound].reversed().prefix { $0 != "\n" && $0 != "\r" }.reversed()
        let preceding = line.last { !$0.isWhitespace && !"«“\"'([—".contains($0) }
        guard preceding == nil || preceding.map({ ".!?…".contains($0) }) == true else { return spelling }
        return spelling.prefix(1).uppercased() + spelling.dropFirst()
    }

    private static func spellingKey(_ text: String) -> String {
        text.filter { !$0.isWhitespace && $0 != "-" }.lowercased().replacingOccurrences(of: "ё", with: "е")
    }

    private static func spellingPattern(_ text: String) -> String {
        text.map { character in
            if character == "ё" || character == "Ё" { return "[её]" }
            if character == "-" { return #"(?:[-‐‑]|\s+)?"# }
            return NSRegularExpression.escapedPattern(for: String(character))
        }.joined()
    }
}
