import Foundation

public struct TermCandidate: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let occurrences: [TermOccurrence]
}

public struct TermOccurrence: Identifiable, Sendable {
    public var id: String { "\(segmentID.uuidString):\(range.location):\(range.length)" }
    public let segmentID: UUID
    public let range: NSRange
    public let text: String
    fileprivate let source: String
}

public enum TranscriptTerms {
    private static let separators = CharacterSet(charactersIn: ",;\n\r")
    private static let leadingBoundary = #"(?<![\p{L}\p{M}\p{N}_/\\@\-‐‑])(?<![\p{L}\p{M}\p{N}]['’])"#
    private static let trailingBoundary = #"(?![\p{L}\p{M}\p{N}_/\\@\-‐‑])(?!['’][\p{L}\p{M}\p{N}])"#
    private static let word = try! NSRegularExpression(
        pattern: leadingBoundary + #"[\p{L}\p{N}][\p{L}\p{M}\p{N}\-‐‑]*(?:['’][\p{L}\p{M}\p{N}]+)*"# + trailingBoundary
    )
    private static let sentenceBreaks = Set<Character>(".!?…\n\r")
    private static let commonLatin: Set<String> = [
        "and", "but", "for", "from", "have", "hello", "into", "just", "like",
        "more", "okay", "please", "sorry", "that", "the", "their", "then", "there",
        "these", "they", "this", "very", "was", "were", "what", "when", "which",
        "will", "with", "would", "yeah", "you", "your"
    ]

    public static func candidates(in segments: [TranscriptSegment], vocabulary: String) -> [TermCandidate] {
        let known = Set(vocabulary.components(separatedBy: separators).map(key))
        struct Group {
            var text: String
            var score = 0
            var occurrences: [TermOccurrence] = []
        }
        var groups: [String: Group] = [:]

        for segment in segments {
            let text = segment.text
            let protected = TranscriptOrthography.literalRanges(in: text)
            for match in word.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { continue }
                let token = String(text[range])
                let normalized = key(token)
                guard (2...48).contains(token.count), !known.contains(normalized),
                      token.contains(where: \.isLetter) else { continue }

                let stem = String(token.prefix { $0 != "'" && $0 != "’" })
                let score = signal(for: stem, normalized: key(stem), preceding: text[..<range.lowerBound])
                if score > (groups[normalized]?.score ?? 0) {
                    groups[normalized, default: Group(text: token)].score = score
                    groups[normalized, default: Group(text: token)].text = token
                }
                groups[normalized, default: Group(text: token)].occurrences.append(occurrence(match.range, in: segment, text: token))
            }
        }

        return groups
            .filter { $0.value.score >= 3 || ($0.value.score > 0 && $0.value.occurrences.count >= 2) }
            .sorted { lhs, rhs in
                if lhs.value.score != rhs.value.score { return lhs.value.score > rhs.value.score }
                if lhs.value.occurrences.count != rhs.value.occurrences.count {
                    return lhs.value.occurrences.count > rhs.value.occurrences.count
                }
                return lhs.key < rhs.key
            }
            .prefix(16)
            .map { TermCandidate(id: $0.key, text: $0.value.text, occurrences: $0.value.occurrences) }
    }

    public static func matches(_ term: String, in segments: [TranscriptSegment]) -> [TermOccurrence] {
        let words = term.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let body = words.map { word in
            word.replacingOccurrences(of: "’", with: "'")
                .components(separatedBy: "'")
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "['’]")
        }.joined(separator: #"\p{Zs}+"#)
        let pattern = leadingBoundary + body + trailingBoundary
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return segments.flatMap { segment -> [TermOccurrence] in
            let text = segment.text
            let protected = TranscriptOrthography.literalRanges(in: text)
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match -> TermOccurrence? in
                guard let range = Range(match.range, in: text),
                      !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { return nil }
                return occurrence(match.range, in: segment, text: String(text[range]))
            }
        }
    }

    public static func replacing(_ occurrences: [TermOccurrence], with replacement: String,
                                 in segments: [TranscriptSegment]) -> [TranscriptSegment]? {
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replacement.isEmpty, replacement.rangeOfCharacter(from: .newlines) == nil else { return nil }
        var pending = Dictionary(grouping: occurrences, by: \.segmentID)
        var result = segments
        for index in segments.indices {
            let segment = segments[index]
            guard let selected = pending.removeValue(forKey: segment.id) else { continue }
            let edited = NSMutableString(string: segment.text)
            var end = edited.length
            for item in selected.sorted(by: { $0.range.location > $1.range.location }) {
                guard item.source == segment.text, item.range.length > 0,
                      let range = Range(item.range, in: segment.text), NSMaxRange(item.range) <= end,
                      segment.text[range] == item.text else { return nil }
                edited.replaceCharacters(in: item.range, with: replacement)
                end = item.range.location
            }
            result[index].text = edited as String
        }
        return pending.isEmpty ? result : nil
    }

    public static func adding(_ term: String, to vocabulary: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: \.isLetter), trimmed.rangeOfCharacter(from: separators) == nil,
              trimmed.rangeOfCharacter(from: .newlines) == nil else { return vocabulary }
        let normalized = key(trimmed)
        guard !vocabulary.components(separatedBy: separators).contains(where: { key($0) == normalized }) else {
            return vocabulary
        }
        if vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return trimmed }
        return vocabulary + (vocabulary.hasSuffix("\n") ? "" : "\n") + trimmed
    }

    private static func key(_ term: String) -> String {
        term.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func occurrence(_ range: NSRange, in segment: TranscriptSegment, text: String) -> TermOccurrence {
        TermOccurrence(segmentID: segment.id, range: range, text: text, source: segment.text)
    }

    private static func signal(for token: String, normalized: String, preceding: Substring) -> Int {
        let letters = token.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return 4 }
        if token.contains(where: \.isNumber) || (letters.first?.isLowercase == true && letters.contains(where: \.isUppercase)) {
            return 3
        }
        if token.first?.isUppercase == true,
           let previous = preceding.last(where: { !$0.isWhitespace && !"«“\"'([—".contains($0) }),
           !sentenceBreaks.contains(previous) {
            return 3
        }
        if token.contains(where: { "-‐‑".contains($0) }) ||
            (token.count >= 4 && token.allSatisfy({ $0.isASCII && $0.isLetter }) && !commonLatin.contains(normalized)) {
            return 1
        }
        return 0
    }
}
