import Foundation

/// A primary decoder can repeat a group of zeros while writing a spoken number.
enum RecognitionNumberMagnitude {
    static func isStandaloneCandidate(_ original: String) -> Bool {
        guard original.contains("000"), let only = mentions(in: original)[Context(left: [], right: [])]?.first else {
            return false
        }
        return only.digits?.hasSuffix("000") == true
    }

    static func needsVerification(_ original: String) -> Bool {
        original.contains("000") && mentions(in: original).values.contains {
            $0.count == 1 && $0[0].digits?.hasSuffix("000") == true
        }
    }

    static func hasShorterReading(original: String, acoustic: String) -> Bool {
        !proposals(original: original, acoustic: acoustic).isEmpty
    }

    static func revisedText(original: String, acoustic: String, reread: String) -> String? {
        let checked = mentions(in: reread)
        let changes = proposals(original: original, acoustic: acoustic).filter { change in
            guard let readings = checked[change.context], readings.count == 1,
                  let reading = readings.first else { return false }
            if let digits = reading.digits { return digits == change.digits }
            if change.context.left.isEmpty && change.context.right.isEmpty && !reading.key.contains(" ")
                && !standaloneScales.contains(reading.key) {
                // A lone word such as “три” can also be a verb without sentence context.
                return false
            }
            return spokenForms(of: change.digits).contains(reading.key)
        }
        guard !changes.isEmpty else { return nil }
        let result = NSMutableString(string: original)
        for change in changes.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: change.range, with: change.replacement)
        }
        return result as String
    }

    private struct Context: Hashable {
        let left: [String]
        let right: [String]
    }

    private struct Mention {
        let range: NSRange
        let key: String
        let digits: String?
    }

    private struct Proposal {
        let context: Context
        let range: NSRange
        let digits: String
        let replacement: String
    }

    private static func proposals(original: String, acoustic: String) -> [Proposal] {
        guard original.contains("000") else { return [] }
        let evidence = mentions(in: acoustic)
        return mentions(in: original).compactMap { context, sources in
            guard sources.count == 1, let source = sources.first, let before = source.digits,
                  let matches = evidence[context], matches.count == 1, let shorter = matches.first,
                  let after = shorter.digits, before.count > after.count, before.hasPrefix(after) else { return nil }
            let extra = before.dropFirst(after.count)
            guard extra.count.isMultiple(of: 3), extra.allSatisfy({ $0 == "0" }) else { return nil }
            return Proposal(context: context, range: source.range, digits: after,
                            replacement: (acoustic as NSString).substring(with: shorter.range))
        }
    }

    private struct Part {
        var key: String
        var range: NSRange
        let numeral: Bool
    }

    private static let words = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}_]+"#)
    private static let standaloneScales: Set<String> = ["тысяча", "миллион", "миллиард", "триллион", "квадриллион", "квинтиллион"]
    private static let genderedUnits: [Substring: [String]] = ["один": ["одна", "одно"], "два": ["две"]]
    private static let cardinals = Set("""
        ноль один одна одно два две три четыре пять шесть семь восемь девять десять одиннадцать двенадцать
        тринадцать четырнадцать пятнадцать шестнадцать семнадцать восемнадцать девятнадцать двадцать тридцать
        сорок пятьдесят шестьдесят семьдесят восемьдесят девяносто сто двести триста четыреста пятьсот
        шестьсот семьсот восемьсот девятьсот тысяча тысячи тысяч миллион миллиона миллионов миллиард
        миллиарда миллиардов триллион триллиона триллионов квадриллион квадриллиона квадриллионов
        квинтиллион квинтиллиона квинтиллионов
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    private static let identifierWords: Set<String> = [
        "id", "pin", "sku", "isbn", "iban", "code", "number", "serial", "reference",
        "инн", "бик", "огрн", "снилс", "номер", "номером", "код", "кодом", "идентификатор",
        "артикул", "индекс", "телефон", "телефону", "версии", "версия", "минус", "плюс", "точка", "запятая"
    ]

    private static func mentions(in text: String) -> [Context: [Mention]] {
        let string = text as NSString
        var parts: [Part] = []
        for match in words.matches(in: text, range: NSRange(location: 0, length: string.length)) {
            let key = string.substring(with: match.range).lowercased().replacingOccurrences(of: "ё", with: "е")
            let numeral = key.utf8.allSatisfy { (48...57).contains($0) } || cardinals.contains(key)
            if numeral, let previous = parts.last, previous.numeral {
                let end = NSMaxRange(previous.range)
                let gap = string.substring(with: NSRange(location: end, length: match.range.location - end))
                if gap.rangeOfCharacter(from: CharacterSet.whitespaces.inverted) == nil {
                    parts[parts.count - 1].key += " " + key
                    parts[parts.count - 1].range = NSUnionRange(previous.range, match.range)
                    continue
                }
            }
            parts.append(Part(key: key, range: match.range, numeral: numeral))
        }
        var result: [Context: [Mention]] = [:]
        let literals = TranscriptOrthography.literalRanges(in: text)
        for (i, part) in parts.enumerated() where part.numeral {
            let left = parts[..<i].suffix(2), right = parts[(i + 1)...].prefix(2)
            // With no surrounding words, all three models must supply the whole turn as
            // a number. Never discard affixes such as a currency, sign or code marker.
            let wholeTurn = parts.count == 1 && isWholeTurn(part.range, in: string)
            guard wholeTurn || left.count + right.count >= 2,
                  left.last?.numeral != true, right.first?.numeral != true,
                  !left.contains(where: { identifierWords.contains($0.key) }),
                  !literals.contains(where: { NSIntersectionRange($0, part.range).length > 0 }) else { continue }
            let previousEnd = left.last.map { NSMaxRange($0.range) } ?? 0
            let nextStart = right.first?.range.location ?? string.length
            let leading = string.substring(with: NSRange(location: previousEnd, length: part.range.location - previousEnd))
            let trailing = string.substring(with: NSRange(location: NSMaxRange(part.range), length: nextStart - NSMaxRange(part.range)))
            let separators = leading + trailing
            // A leading decimal separator, currency sign or percent/comparison mark
            // changes what the digits denote. Other decoders may omit that mark.
            guard leading.last != ".", leading.last != ",",
                  separators.rangeOfCharacter(from: .symbols) == nil,
                  !separators.contains(where: { "-‐‑–—/:_#@\\`%‰‱*".contains($0) }) else { continue }
            let context = Context(left: left.map(\.key), right: right.map(\.key))
            result[context, default: []].append(Mention(range: part.range, key: part.key, digits: digits(in: part.key)))
        }
        return result
    }

    private static func isWholeTurn(_ range: NSRange, in text: NSString) -> Bool {
        let prefix = text.substring(to: range.location).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = text.substring(from: NSMaxRange(range)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty && ["", ".", "!", "?", "…"].contains(suffix)
    }

    private static func digits(in key: String) -> String? {
        let groups = key.split(separator: " ")
        guard let first = groups.first, first.first != "0",
              groups.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              groups.count == 1 || (first.count <= 3 && groups.dropFirst().allSatisfy { $0.count == 3 }) else { return nil }
        return groups.joined()
    }

    private static func spokenForms(of digits: String) -> Set<String> {
        guard let value = Int64(digits) else { return [] }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .spellOut
        guard let spelled = formatter.string(from: NSNumber(value: value)) else { return [] }
        var forms = [spelled]
        // Russian permits the leading one to be implicit in an exact scale.
        if spelled.hasPrefix("один ") || spelled.hasPrefix("одна ") {
            forms.append(String(spelled.dropFirst(5)))
        }
        // The formatter spells bare integers in the masculine. Only the final
        // unit agrees with the counted noun, including in a compound numeral.
        if let unit = spelled.split(separator: " ").last, let variants = genderedUnits[unit] {
            forms += forms.flatMap { form in
                variants.map { form.dropLast(unit.count) + $0 }
            }
        }
        // In “два миллиона пятьсот” the hundreds refer to the next group.
        // Accept that reading only for the value independently written in digits.
        var significant = value
        while significant >= 1000 && significant.isMultiple(of: 1000) { significant /= 1000 }
        let lastGroup = significant % 1000
        if significant < value, (significant / 1000) % 1000 > 0,
           lastGroup >= 100, lastGroup.isMultiple(of: 100) {
            forms += forms.map { $0.split(separator: " ").dropLast().joined(separator: " ") }
        }
        return Set(forms)
    }
}
