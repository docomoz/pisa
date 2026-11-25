import Foundation

struct RecognitionAcousticResult: Codable {
    let text: String
    let words: [RecognitionTimedWord]

    /// Put an isolated read's word times back on its parent audio interval.
    func offsettingWords(by offset: Double) -> Self {
        guard offset != 0 else { return self }
        return Self(text: text, words: words.map {
            RecognitionTimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset)
        })
    }
}

struct RecognitionTimedWord: Equatable, Codable {
    let text: String
    let start: Double
    let end: Double
}

enum RecognitionTimedWords {
    private static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?"#)

    /// Align only when every reconstructed token word matches the text. A token
    /// may contain several words: those words share its conservative interval.
    static func map(text: String, tokens: [String], timestamps: [Double], duration: Double) -> [RecognitionTimedWord] {
        guard duration.isFinite, duration > 0, !tokens.isEmpty,
              tokens.count == timestamps.count, timestamps.allSatisfy(\.isFinite),
              zip(timestamps, timestamps.dropFirst()).allSatisfy({ $0 <= $1 }) else { return [] }
        var joined = ""
        var spans: [NSRange] = []
        for token in tokens {
            let piece = token.replacingOccurrences(of: "▁", with: " ")
            let location = (joined as NSString).length
            joined += piece
            spans.append(NSRange(location: location, length: (piece as NSString).length))
        }
        let source = pattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        let decoded = pattern.matches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length))
        guard !source.isEmpty, source.count == decoded.count else { return [] }
        let input = text as NSString, reconstructed = joined as NSString
        let bounded = timestamps.map { min(duration, max(0, $0)) }
        var result: [RecognitionTimedWord] = []
        for (actual, tokenWord) in zip(source, decoded) {
            let word = input.substring(with: actual.range)
            guard word.lowercased() == reconstructed.substring(with: tokenWord.range).lowercased() else { return [] }
            let indexes = spans.indices.filter { NSIntersectionRange(spans[$0], tokenWord.range).length > 0 }
            guard let first = indexes.first, let last = indexes.last else { return [] }
            let end = last + 1 < bounded.count ? bounded[last + 1] : duration
            result.append(RecognitionTimedWord(text: word, start: bounded[first], end: max(bounded[first], end)))
        }
        return result
    }
}

/// A padded decode can mistake the beginning of a neighboring word for a
/// short particle. Only the words independently heard inside the turn survive.
struct RecognitionTrailingFragment {
    let prefix: String
    let paddedWords: [String]

    init?(source: String, acoustic: RecognitionAcousticResult, core: Range<Int>, sampleCount: Int) {
        guard let match = Self.sourcePattern.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let prefixRange = Range(match.range(at: 1), in: source), let fragment = Range(match.range(at: 2), in: source),
              let last = acoustic.words.last, core.upperBound <= sampleCount else { return nil }
        let heard = RussianRecognition.words(acoustic.text)
        let prefix = String(source[prefixRange]), end = Double(core.upperBound) / 16000
        guard heard == acoustic.words.map({ $0.text.lowercased().replacingOccurrences(of: "ё", with: "е") }),
              heard.dropLast().elementsEqual(RussianRecognition.words(prefix)), let word = heard.last,
              word.count >= 4, word.first == source[fragment].lowercased().first,
              word.unicodeScalars.allSatisfy({ (0x430...0x44F).contains($0.value) }), !AbbreviationFamilies.isRussianFunctionWord(word),
              last.start.isFinite, last.end.isFinite,
              last.start >= end - 0.16, last.start < end,
              last.end >= end + 0.06, last.end <= Double(sampleCount) / 16000 + 0.001,
              last.end - end >= (last.end - last.start) / 3 else { return nil }
        self.prefix = prefix
        paddedWords = heard
    }

    private static let sourcePattern = try! NSRegularExpression(pattern: #"(?i)^([а-яё]+(?: [а-яё]+){0,4}) ([а-яё]{1,2})$"#)

    func matchesCore(_ text: String?) -> Bool {
        text.map(RussianRecognition.words) == Array(paddedWords.dropLast())
    }

    func confirmedText(padded: String, paddedLanguage: String?, exact: String, exactLanguage: String?) -> String? {
        guard paddedLanguage?.lowercased() == "russian", exactLanguage?.lowercased() == "russian",
              RussianRecognition.words(padded) == paddedWords, matchesCore(exact) else { return nil }
        return prefix
    }
}
