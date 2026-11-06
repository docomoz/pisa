import Foundation

struct RecognitionTimedWord: Equatable {
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
