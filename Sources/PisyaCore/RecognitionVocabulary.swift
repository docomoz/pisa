import Foundation

/// Render explicitly supplied dictionary entries consistently. This is spelling
/// normalization, not fuzzy replacement of names inferred from transcript text.
enum RecognitionVocabulary {
    static func apply(to text: String, vocabulary: String) -> String {
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        var result = text
        let numbers = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять",
                       "десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать",
                       "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать", "двадцать"]
        for term in terms {
            let digits = String(term.prefix(while: \.isNumber))
            let acronym = String(term.dropFirst(digits.count))
            var pattern = term.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
            // A numeric acronym can be spoken with a Russian number and case
            // ending. Derive the forms from the user's entry (e.g. 7АБВ).
            if let number = Int(digits), numbers.indices.contains(number),
               (2...8).contains(acronym.count), acronym.allSatisfy(\.isLetter),
               acronym == acronym.uppercased(), acronym != acronym.lowercased() {
                let latin = acronym.applyingTransform(.toLatin, reverse: false) ?? acronym
                let stems = Array(Set([acronym, latin])).sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|")
                // ASR can merge the numeral with the name and spell an unstressed
                // а/о differently. Restrict this equivalence to the known numeral
                // prefix of an explicit dictionary acronym, not arbitrary words.
                let spoken = numbers[number].map { "ао".contains($0) ? "[ао]" : NSRegularExpression.escapedPattern(for: String($0)) }.joined()
                pattern = "(?:\(NSRegularExpression.escapedPattern(for: digits))|\(spoken))[\\s-]*(?:\(stems))(?:а|у|ом|е|ы|ов|ам|ами|ах|a|u|om|e)?"
            }
            guard let expression = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + pattern + #")(?![\p{L}\p{N}])"#, options: [.caseInsensitive]) else { continue }
            result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: NSRegularExpression.escapedTemplate(for: term))
        }
        return result
    }
}
