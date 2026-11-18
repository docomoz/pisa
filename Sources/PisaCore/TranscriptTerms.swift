import Foundation
import NaturalLanguage

public struct TermCandidate: Identifiable, Sendable {
    public let id: String
    public let text: String
    public let occurrences: [TermOccurrence]
    public let observedLabel: String
    let alternativeSpellings: String?

    fileprivate init(id: String, text: String, occurrences: [TermOccurrence]) {
        self.id = id
        self.text = text
        self.occurrences = occurrences
        let forms = Set(occurrences.map(\.text))
        let observed = forms.contains(text) ? text : occurrences[0].text
        observedLabel = observed
        let alternatives = forms.filter { $0.lowercased() != observed.lowercased() }.sorted()
        alternativeSpellings = alternatives.isEmpty ? nil : alternatives.joined(separator: ", ")
    }
}

public struct TermOccurrence: Identifiable, Sendable {
    public var id: String { "\(segmentID.uuidString):\(range.location):\(range.length)" }
    public let segmentID: UUID
    public let range: NSRange
    public let text: String
    fileprivate let family: AbbreviationFamilies.Form?
    fileprivate let source: String

    fileprivate struct Spelling: Hashable {
        let text: String
        let ending: String?
    }

    fileprivate var spelling: Spelling { Spelling(text: text, ending: family?.ending) }
}

public enum TranscriptTerms {
    private static let separators = CharacterSet(charactersIn: ",;\n\r")
    private static let leadingBoundary = #"(?<![\p{L}\p{M}\p{N}_/\\@\-‐‑])(?<![\p{L}\p{M}\p{N}]['’])"#
    private static let trailingBoundary = #"(?![\p{L}\p{M}\p{N}_/\\@\-‐‑])(?!['’][\p{L}\p{M}\p{N}])"#
    private static let leadingEdge = try! NSRegularExpression(pattern: leadingBoundary)
    private static let trailingEdge = try! NSRegularExpression(pattern: trailingBoundary)
    private static let word = try! NSRegularExpression(
        pattern: leadingBoundary + #"[\p{L}\p{N}][\p{L}\p{M}\p{N}\-‐‑]*(?:['’][\p{L}\p{M}\p{N}]+)*"# + trailingBoundary
    )
    private static let russianOrdinalNumeral = try! NSRegularExpression(
        pattern: #"\A\p{Nd}+[-‐‑](?:[йяеюмх]|го|му|ми)\z"#, options: .caseInsensitive
    )
    private static let sentenceBreaks = Set<Character>(".!?…\n\r")
    private static let commonLatin: Set<String> = [
        "and", "but", "for", "from", "good", "have", "hello", "into", "just", "like",
        "more", "okay", "please", "right", "sorry", "that", "the", "their", "then", "there",
        "these", "they", "think", "this", "very", "was", "well", "were", "what", "when", "which",
        "will", "with", "would", "yeah", "you", "your"
    ]
    private static let entityForms: Set<String> = {
        Set(wordFormData(named: "PisaEntityForms").split(separator: 0x0A).map { String(decoding: $0, as: UTF8.self) })
    }()
    private static let commonForms = wordFormData(named: "PisaCommonForms")
    private static let russianParticles = ["-то", "-либо", "-нибудь", "-ка"]

    private static func wordFormData(named resource: String) -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: resource, withExtension: "deflate"),
              let compressed = NSData(contentsOf: url),
              let data = try? compressed.decompressed(using: .zlib) else { return Data() }
        return Data(referencing: data)
    }

    public static func candidates(in segments: [TranscriptSegment], vocabulary: String) -> [TermCandidate] {
        let terms = vocabulary.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let known = Set(terms.flatMap { [$0] + RecognitionVocabulary.cyrillicInflections(of: $0) }.map(key))
        let families = AbbreviationFamilies(vocabulary)
        let technology = TechnologyVocabulary(personalVocabulary: vocabulary)
        let speakers = speakerNameForms(in: segments)
        let tagger = NLTagger(tagSchemes: [.nameType])
        struct Group {
            var text: String
            var score = 0
            var occurrences: [TermOccurrence] = []
        }
        var groups: [String: Group] = [:]
        var technologyGroups: [String: Group] = [:]
        // The same spelling occurs in many turns. Its dictionary and family
        // classification is independent of the surrounding sentence.
        var eligibleForms: [String: (normalized: String, family: AbbreviationFamilies.Form?)?] = [:]

        func rankedCandidates() -> [TermCandidate] {
            groups.merging(technologyGroups) { _, validated in validated }
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

        for segment in segments {
            guard !Task.isCancelled else { return [] }
            let text = segment.text
            let protected = TranscriptOrthography.literalRanges(in: text)
            let builtIn = technology.matches(in: text, literalRanges: protected).filter { !speakers.contains(entityKey($0.term)) }
            for match in builtIn {
                let normalized = key(match.term)
                guard !known.contains(normalized), !TechnologyVocabulary.isHiddenFromCandidates(match.term) else { continue }
                technologyGroups[normalized, default: Group(text: match.term, score: 4)]
                    .occurrences.append(technologyOccurrence(match, in: segment))
            }
            let literals = protected + builtIn.map(\.range)
            var taggedNames: [NSRange]?
            for match in word.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range, in: text),
                      !literals.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
                else { continue }
                let token = String(text[range])
                if eligibleForms[token] == nil {
                    // A lowercase or sentence-case function word can otherwise
                    // join an uppercase acronym through the case-folded key.
                    let plainFunctionWord = AbbreviationFamilies.isRussianFunctionWord(token) && token != token.uppercased()
                    if (2...48).contains(token.count), token.contains(where: \.isLetter),
                       !plainFunctionWord, !known.contains(key(token)), families.known(token) == nil,
                       !TechnologyVocabulary.isHiddenFromCandidates(token),
                       russianOrdinalNumeral.firstMatch(in: token, range: NSRange(location: 0, length: match.range.length)) == nil {
                        let family = families.form(token)
                        eligibleForms.updateValue((key(family?.base ?? token), family), forKey: token)
                    } else {
                        eligibleForms.updateValue(nil, forKey: token)
                    }
                }
                guard let entry = eligibleForms[token], let (normalized, family) = entry else { continue }

                let stem = family?.base ?? String(token.prefix { $0 != "'" && $0 != "’" })
                let score = signal(for: stem, normalized: key(stem), preceding: text[..<range.lowerBound])
                if score > 0 {
                    let entity = entityKey(stem)
                    guard !entityForms.contains(entity), !speakers.contains(entity) else { continue }
                    // An acronym can have the same lowercase spelling as a dictionary word.
                    if family == nil, isCommonRussianWord(entity) { continue }
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

        return rankedCandidates()
    }

    public static func matches(_ term: String, in segments: [TranscriptSegment], vocabulary: String = "") -> [TermOccurrence] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TechnologyVocabulary.isCanonical(trimmed) else {
            return literalMatches(trimmed, in: segments, vocabulary: vocabulary)
        }
        let technology = TechnologyVocabulary(personalVocabulary: vocabulary)
        let normalized = key(trimmed)
        let validated = collectMatches(in: segments) { segment in
            technology.matches(in: segment.text).filter { key($0.term) == normalized }.map { technologyOccurrence($0, in: segment) }
        }
        guard TechnologyVocabulary.isHiddenFromCandidates(trimmed)
                || VocabularyDictionary.entries(in: vocabulary).contains(where: { key($0.text) == normalized }) else {
            return validated
        }
        // Include case variants of hidden terms and personal spellings that
        // the normalizer protects, alongside the validated aliases.
        let literal = literalMatches(trimmed, in: segments, vocabulary: vocabulary)
        var bySegment: [UUID: [NSRange: TermOccurrence]] = [:]
        for occurrence in literal + validated {
            bySegment[occurrence.segmentID, default: [:]][occurrence.range] = occurrence
        }
        return collectMatches(in: segments) { segment in
            bySegment[segment.id, default: [:]].values.sorted { $0.range.location < $1.range.location }
        }
    }

    private static func literalMatches(_ trimmed: String, in segments: [TranscriptSegment], vocabulary: String) -> [TermOccurrence] {
        let families = AbbreviationFamilies(vocabulary)
        let knownQuery = families.known(trimmed)
        let base = knownQuery.flatMap { $0.ending.isEmpty ? $0.base : nil } ?? trimmed
        let abbreviation = AbbreviationFamilies.isBase(base)
        if abbreviation || (TechnologyVocabulary.isCanonical(base) && TechnologyVocabulary.supportsEndings(for: base)) {
            let queryFamily = AbbreviationFamilies(base)
            let baseKey = key(base)
            var formsByToken: [String: AbbreviationFamilies.Form?] = [:]
            return collectMatches(in: segments) { segment in
                let text = segment.text
                let protected = TranscriptOrthography.literalRanges(in: text)
                return word.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                    guard let range = Range(match.range, in: text),
                          !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) else { return nil }
                    let token = String(text[range])
                    if formsByToken[token] == nil {
                        let form: AbbreviationFamilies.Form?
                        if abbreviation {
                            form = families.isExplicit(token) || families.hasKnownBase(token)
                                ? families.known(token) : queryFamily.known(token)
                        } else {
                            // A saved catalog name can protect its written span in
                            // the technology matcher while still taking endings.
                            form = AbbreviationFamilies.parse(token, as: base).flatMap { parsed in
                                let competingSpelling = key(token) != baseKey && families.isExplicit(token)
                                return !competingSpelling && !families.hasKnownBase(token) ? parsed : nil
                            }
                        }
                        formsByToken.updateValue(form, forKey: token)
                    }
                    guard let form = formsByToken[token] ?? nil, key(form.base) == baseKey else { return nil }
                    return occurrence(match.range, in: segment, text: token, family: form)
                }
            }
        }
        let words = trimmed.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return [] }
        let body = words.map { word in
            word.replacingOccurrences(of: "’", with: "'")
                .components(separatedBy: "'")
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "['’]")
        }.joined(separator: #"\p{Zs}+"#)
        let pattern = leadingBoundary + body + trailingBoundary
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return collectMatches(in: segments) { segment in
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

    private static func collectMatches(in segments: [TranscriptSegment],
                                       find: (TranscriptSegment) -> [TermOccurrence]) -> [TermOccurrence] {
        var matches: [TermOccurrence] = []
        for segment in segments {
            guard !Task.isCancelled else { return [] }
            matches.append(contentsOf: find(segment))
        }
        return matches
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

    // Patch the selected contexts immediately. The corrected spelling can
    // have other occurrences, which are added by the subsequent search.
    static func correctedOccurrences(_ occurrences: [TermOccurrence], with replacement: String,
                                     in segments: [UUID: TranscriptSegment]) -> [TermOccurrence] {
        var offsets: [UUID: Int] = [:]
        return occurrences.compactMap { item in
            guard let segment = segments[item.segmentID], let rendered = self.replacement(for: item, with: replacement)
            else { return nil }
            let offset = offsets[item.segmentID, default: 0]
            let range = NSRange(location: item.range.location + offset, length: rendered.utf16.count)
            offsets[item.segmentID] = offset + range.length - item.range.length
            return occurrence(range, in: segment, text: rendered)
        }
    }

    // Keep the worklist in place after a correction. A reviewed spelling
    // that was already correct is resolved alongside the spans that changed.
    static func retainingCandidates(_ candidates: [TermCandidate], afterReplacing occurrences: [TermOccurrence],
                                    with replacement: String, in segmentsByID: [UUID: TranscriptSegment]) -> [TermCandidate] {
        let edits = Dictionary(grouping: occurrences, by: \.segmentID).compactMapValues { occurrences in
            let offsets = occurrences.compactMap { occurrence -> (range: NSRange, offset: Int)? in
                guard let rendered = self.replacement(for: occurrence, with: replacement) else { return nil }
                return (occurrence.range, rendered.utf16.count - occurrence.range.length)
            }
            return offsets.isEmpty ? nil : offsets
        }
        let literals = edits.keys.reduce(into: [UUID: [NSRange]]()) { result, id in
            if let text = segmentsByID[id]?.text { result[id] = TranscriptOrthography.literalRanges(in: text) }
        }
        return candidates.compactMap { candidate in
            let retained = candidate.occurrences.compactMap { item -> TermOccurrence? in
                guard let segmentEdits = edits[item.segmentID] else { return item }
                var offset = 0
                var touchesEdit = false
                for edit in segmentEdits {
                    let start = item.range.location
                    let end = NSMaxRange(item.range)
                    if NSMaxRange(edit.range) <= start {
                        offset += edit.offset
                        touchesEdit = touchesEdit || NSMaxRange(edit.range) == start
                    } else if edit.range.location < end {
                        return nil
                    } else {
                        touchesEdit = touchesEdit || edit.range.location == end
                    }
                }
                guard let segment = segmentsByID[item.segmentID] else { return nil }
                let range = NSRange(location: item.range.location + offset, length: item.range.length)
                guard let protected = literals[item.segmentID],
                      !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      let indices = Range(range, in: segment.text),
                      segment.text[indices] == item.text else { return nil }
                if touchesEdit {
                    let left = NSRange(location: range.location, length: 0)
                    let right = NSRange(location: NSMaxRange(range), length: 0)
                    guard leadingEdge.firstMatch(in: segment.text, options: .withTransparentBounds, range: left) != nil,
                          trailingEdge.firstMatch(in: segment.text, options: .withTransparentBounds, range: right) != nil
                    else { return nil }
                }
                return occurrence(range, in: segment, text: item.text, family: item.family)
            }
            guard !retained.isEmpty else { return nil }
            return TermCandidate(id: candidate.id, text: candidate.text, occurrences: retained)
        }
    }

    static func retainingCandidates(_ candidates: [TermCandidate], afterAdding term: String) -> [TermCandidate] {
        let known = Set(([term] + RecognitionVocabulary.cyrillicInflections(of: term)).map(key))
        let families = AbbreviationFamilies(term)
        let technology = TechnologyVocabulary(personalVocabulary: term)
        let isPhrase = term.contains(where: \.isWhitespace)
        var phraseRangesBySegment: [UUID: [NSRange]] = [:]
        return candidates.compactMap { candidate in
            guard !known.contains(candidate.id), families.known(candidate.text) == nil else { return nil }
            let builtIn = TechnologyVocabulary.isCanonical(candidate.text)
            var knownSpellings: [TermOccurrence.Spelling: Bool] = [:]
            let retained = candidate.occurrences.filter { item in
                if knownSpellings[item.spelling] == nil {
                    let spokenBase = String(item.text.dropLast(item.family?.ending.count ?? 0))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
                    knownSpellings[item.spelling] = known.contains(key(item.text)) || families.known(item.text) != nil ||
                        (builtIn && technology.hasPersonalSpokenSpelling(spokenBase))
                }
                guard knownSpellings[item.spelling] == false else { return false }
                guard isPhrase, builtIn else { return true }
                if phraseRangesBySegment[item.segmentID] == nil {
                    phraseRangesBySegment[item.segmentID] = technology.personalPhraseRanges(in: item.source)
                }
                return phraseRangesBySegment[item.segmentID]?.contains {
                    NSIntersectionRange($0, item.range).length > 0
                } != true
            }
            guard !retained.isEmpty else { return nil }
            if retained.count == candidate.occurrences.count { return candidate }
            return TermCandidate(id: candidate.id, text: candidate.text, occurrences: retained)
        }
    }

    // Replacement only depends on the spelling and the presence and value of
    // its ending. The form need not revalidate every occurrence on each key press.
    static func distinctSpellings(in occurrences: [TermOccurrence]) -> [TermOccurrence] {
        var seen: Set<TermOccurrence.Spelling> = []
        return occurrences.filter { seen.insert($0.spelling).inserted }
    }

    struct DictionaryAdditions {
        private let families: AbbreviationFamilies
        private let terms: Set<String>

        init(_ vocabulary: String) {
            families = AbbreviationFamilies(vocabulary)
            terms = Set(vocabulary.components(separatedBy: separators).map(key))
        }

        func termToAdd(_ term: String) -> String? {
            let trimmed = dictionaryTerm(term)
            guard trimmed.contains(where: \.isLetter), trimmed.rangeOfCharacter(from: separators) == nil,
                  trimmed.rangeOfCharacter(from: .newlines) == nil,
                  !terms.contains(key(trimmed)), families.known(trimmed) == nil else { return nil }
            return trimmed
        }
    }

    public static func adding(_ term: String, to vocabulary: String) -> String {
        guard let trimmed = DictionaryAdditions(vocabulary).termToAdd(term) else { return vocabulary }
        if vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return trimmed }
        return vocabulary + (vocabulary.hasSuffix("\n") ? "" : "\n") + trimmed
    }

    public static func dictionaryTerm(_ term: String) -> String {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return AbbreviationFamilies.inferred(trimmed)?.base ?? apostrophizedTechnologyBase(trimmed) ?? trimmed
    }

    /// The preview and mutation share this renderer. Family edits keep each
    /// observed ending and accept an explicitly apostrophized spelling.
    public static func replacement(for occurrence: TermOccurrence, with replacement: String) -> String? {
        let trimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .newlines) == nil else { return nil }
        guard let family = occurrence.family else { return trimmed }
        let base = apostrophizedBase(trimmed) ?? trimmed
        guard !family.ending.isEmpty else { return base }
        guard AbbreviationFamilies.isBase(base) || TechnologyVocabulary.supportsEndings(for: base) else { return nil }
        return AbbreviationFamilies.Form(base: base, ending: family.ending).text
    }

    public static func replacementSearchTerm(for occurrences: [TermOccurrence], with replacement: String) -> String {
        guard occurrences.contains(where: { $0.family != nil }) else { return replacement }
        return apostrophizedBase(replacement) ?? replacement
    }

    private static func apostrophizedBase(_ term: String) -> String? {
        guard term.contains("'") || term.contains("’") else { return nil }
        return AbbreviationFamilies.inferred(term)?.base ?? apostrophizedTechnologyBase(term)
    }

    private static func apostrophizedTechnologyBase(_ term: String) -> String? {
        guard let apostrophe = term.firstIndex(where: { $0 == "'" || $0 == "’" }) else { return nil }
        let base = String(term[..<apostrophe])
        let ending = String(term[term.index(after: apostrophe)...])
        guard AbbreviationFamilies.ending(ending, numeric: false) != nil,
              TechnologyVocabulary.supportsEndings(for: base) else { return nil }
        return base
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

    static func isCommonRussianWord(_ word: String) -> Bool {
        guard word.unicodeScalars.allSatisfy({ (0x430...0x44F).contains($0.value) || $0.value == 0x2D }) else {
            return false
        }
        if containsCommonForm(word) { return true }
        guard let particle = russianParticles.first(where: { word.hasSuffix($0) }) else { return false }
        return containsCommonForm(String(word.dropLast(particle.count)))
    }

    private static func containsCommonForm(_ word: String) -> Bool {
        let query = Array(word.utf8)
        // The resource is sorted UTF-8, one form per line. Search the bytes
        // directly to avoid creating millions of strings on first use.
        return commonForms.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var lower = 0
            var upper = bytes.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                var start = middle
                var end = middle
                while start > lower, bytes[start - 1] != 0x0A { start -= 1 }
                while end < upper, bytes[end] != 0x0A { end += 1 }
                let form = bytes[start..<end]
                if form.elementsEqual(query) { return true }
                if form.lexicographicallyPrecedes(query) {
                    lower = end + 1
                } else {
                    upper = start
                }
            }
            return false
        }
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

    private static func technologyOccurrence(_ match: TechnologyVocabulary.Match, in segment: TranscriptSegment) -> TermOccurrence {
        let supportsEndings = AbbreviationFamilies.isBase(match.term) || TechnologyVocabulary.supportsEndings(for: match.term)
        let family = supportsEndings ? AbbreviationFamilies.Form(base: match.term, ending: match.ending) : nil
        return occurrence(match.range, in: segment, text: (segment.text as NSString).substring(with: match.range), family: family)
    }

    private static func signal(for token: String, normalized: String, preceding: Substring) -> Int {
        let letters = token.filter(\.isLetter)
        if letters.count >= 2, letters.allSatisfy(\.isUppercase) { return 4 }
        if token.contains(where: \.isNumber) || (letters.first?.isLowercase == true && letters.contains(where: \.isUppercase)) {
            return 3
        }
        if commonLatin.contains(normalized) { return 0 }
        if token.first?.isUppercase == true,
           let previous = preceding.last(where: { !$0.isWhitespace && !"«“\"'([—".contains($0) }),
           !sentenceBreaks.contains(previous) {
            return 3
        }
        if token.contains(where: { "-‐‑".contains($0) }) ||
            (token.count >= 4 && token.allSatisfy({ $0.isASCII && $0.isLetter })) {
            return 1
        }
        return 0
    }
}
