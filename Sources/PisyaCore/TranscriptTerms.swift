import Foundation
import NaturalLanguage

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
    fileprivate let family: AbbreviationFamilies.Form?
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
    private static let entityForms: Set<String> = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "PisyaEntityForms", withExtension: "deflate"),
              let compressed = NSData(contentsOf: url),
              let data = try? compressed.decompressed(using: .zlib) else { return [] }
        return Set((data as Data).split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) })
    }()

    public static func candidates(in segments: [TranscriptSegment], vocabulary: String) -> [TermCandidate] {
        let terms = vocabulary.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let known = Set(terms.flatMap { [$0] + RecognitionVocabulary.cyrillicInflections(of: $0) }.map(key))
        let families = AbbreviationFamilies(vocabulary)
        let speakers = speakerNameForms(in: segments)
        let tagger = NLTagger(tagSchemes: [.nameType])
        struct Group {
            var text: String
            var score = 0
            var occurrences: [TermOccurrence] = []
        }
        var groups: [String: Group] = [:]

        for segment in segments {
            let text = segment.text
            let literals = TranscriptOrthography.literalRanges(in: text)
            var taggedNames: [NSRange]?
            for match in word.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      !literals.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { continue }
                let token = String(text[range])
                let family = families.form(token)
                let normalized = key(family?.base ?? token)
                guard (2...48).contains(token.count), !known.contains(key(token)),
                      families.known(token) == nil,
                      token.contains(where: \.isLetter) else { continue }

                let stem = family?.base ?? String(token.prefix { $0 != "'" && $0 != "’" })
                let score = signal(for: stem, normalized: key(stem), preceding: text[..<range.lowerBound])
                if score > 0 {
                    let entity = entityKey(stem)
                    guard !entityForms.contains(entity), !speakers.contains(entity) else { continue }
                    // Contextual tags can mistake acronyms and model names for entities.
                    if family == nil, !stem.contains(where: \.isNumber) {
                        if taggedNames == nil { taggedNames = contextualEntityRanges(in: text, using: tagger) }
                        if taggedNames?.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) == true { continue }
                    }
                }
                if score > (groups[normalized]?.score ?? 0) {
                    groups[normalized, default: Group(text: token)].score = score
                    groups[normalized, default: Group(text: token)].text = family?.base ?? token
                }
                groups[normalized, default: Group(text: family?.base ?? token)].occurrences.append(occurrence(match.range, in: segment, text: token, family: family))
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

    public static func matches(_ term: String, in segments: [TranscriptSegment], vocabulary: String = "") -> [TermOccurrence] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        let families = AbbreviationFamilies(vocabulary)
        let knownQuery = families.known(trimmed)
        let base = knownQuery.flatMap { $0.ending.isEmpty ? $0.base : nil } ?? trimmed
        if AbbreviationFamilies.isBase(base) {
            let queryFamily = AbbreviationFamilies(base)
            return segments.flatMap { segment -> [TermOccurrence] in
                let text = segment.text
                let protected = TranscriptOrthography.literalRanges(in: text)
                return word.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    guard let range = Range(match.range, in: text),
                          !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
                    let token = String(text[range])
                    let form: AbbreviationFamilies.Form?
                    if families.isExplicit(token) || families.hasKnownBase(token) {
                        form = families.known(token)
                    } else {
                        form = queryFamily.known(token)
                    }
                    guard let form, key(form.base) == key(base) else { return nil }
                    return occurrence(match.range, in: segment, text: token, family: form)
                }
            }
        }
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
                guard let rendered = self.replacement(for: item, with: replacement) else { return nil }
                edited.replaceCharacters(in: item.range, with: rendered)
                end = item.range.location
            }
            result[index].text = edited as String
        }
        return pending.isEmpty ? result : nil
    }

    public static func adding(_ term: String, to vocabulary: String) -> String {
        let trimmed = dictionaryTerm(term)
        guard trimmed.contains(where: \.isLetter), trimmed.rangeOfCharacter(from: separators) == nil,
              trimmed.rangeOfCharacter(from: .newlines) == nil else { return vocabulary }
        let normalized = key(trimmed)
        if AbbreviationFamilies(vocabulary).known(trimmed) != nil { return vocabulary }
        guard !vocabulary.components(separatedBy: separators).contains(where: { key($0) == normalized }) else {
            return vocabulary
        }
        if vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return trimmed }
        return vocabulary + (vocabulary.hasSuffix("\n") ? "" : "\n") + trimmed
    }

    public static func dictionaryTerm(_ term: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return AbbreviationFamilies.inferred(trimmed)?.base ?? trimmed
    }

    /// The preview and mutation share this renderer. Family edits keep each
    /// observed ending and accept an explicitly apostrophized spelling.
    public static func replacement(for occurrence: TermOccurrence, with replacement: String) -> String? {
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }
        guard let family = occurrence.family else { return trimmed }
        let base = apostrophizedAbbreviationBase(trimmed) ?? trimmed
        guard !family.ending.isEmpty else { return base }
        guard AbbreviationFamilies.isBase(base) else { return nil }
        return AbbreviationFamilies.Form(base: base, ending: family.ending).text
    }

    public static func replacementSearchTerm(for occurrences: [TermOccurrence], with replacement: String) -> String {
        guard occurrences.contains(where: { $0.family != nil }) else { return replacement }
        return apostrophizedAbbreviationBase(replacement) ?? replacement
    }

    private static func apostrophizedAbbreviationBase(_ term: String) -> String? {
        guard term.contains("'") || term.contains("’") else { return nil }
        return AbbreviationFamilies.inferred(term)?.base
    }

    private static func key(_ term: String) -> String {
        term.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func entityKey(_ term: String) -> String {
        term.lowercased().replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "‐", with: "-").replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func speakerNameForms(in segments: [TranscriptSegment]) -> Set<String> {
        let labels = Set(segments.map(\.speaker))
        return Set(labels.flatMap { label -> [String] in
            guard label != "Собеседники", !label.contains(where: \.isNumber) else { return [] }
            return word.matches(in: label, range: NSRange(label.startIndex..., in: label)).compactMap { match in
                guard let range = Range(match.range, in: label), label[range].count >= 3 else { return nil }
                return entityKey(String(label[range]))
            }
        })
    }

    private static func contextualEntityRanges(in text: String, using tagger: NLTagger) -> [NSRange] {
        tagger.string = text
        var names: [NSRange] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName || tag == .placeName { names.append(NSRange(range, in: text)) }
            return true
        }
        return names
    }

    private static func occurrence(_ range: NSRange, in segment: TranscriptSegment, text: String,
                                   family: AbbreviationFamilies.Form? = nil) -> TermOccurrence {
        TermOccurrence(segmentID: segment.id, range: range, text: text, family: family, source: segment.text)
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
