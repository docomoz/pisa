import Foundation

/// Exact written and spoken technical vocabulary shared by the decoder and term review.
/// The index is local and the decoder sees only terms actually observed in a turn.
struct TechnologyVocabulary {
    struct Match {
        let term: String
        let range: NSRange
        let ending: String
        let replacement: String?
    }

    private struct Pattern {
        let term: String
        let words: [String]
        let spelling: String
        let spoken: Bool
        let personalOnly: Bool
        let requiresContext: Bool
        let requiresCompanyCue: Bool
        let inflectable: Bool
    }

    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*|[.+#/&]"#)
    static let russianEndings = Set(AbbreviationFamilies.endings + ["шками", "шкой", "шкам", "шках", "шек", "шка", "шки", "шку", "шке"])
    private static let endings = russianEndings.sorted { $0.count > $1.count }
    private static let attached = "_/@\\"
    private static let hyphens = "-‐‑"
    private static let dataAmountNouns: Set<String> = ["данных", "памяти", "трафика", "места", "информации"]
    private static let dockerCue = try! NSRegularExpression(pattern:
        #"(?i)\b(?:кубернетес[а-яё]*|kubernetes|dockerfile|podman|депло[яй][а-яё]*|образ[а-яё]*\p{Zs}+контейнер[а-яё]*)\b"#)
    private static let nearbyCues: [String: NSRegularExpression] = [
        "Docker": dockerCue,
        "white-label": try! NSRegularExpression(pattern:
            #"\b(?:продукт[а-яё]*|решени[а-яё]*|технолог[а-яё]*|бренд[а-яё]*|бизнес[а-яё]*|платформ[а-яё]*|направлени[а-яё]*|модел[а-яё]*|партн[её]р[а-яё]*|предлага[а-яё]*|products?|solutions?|services?|platforms?|brands?|business|offer[а-яёa-z]*)\b"#,
            options: .caseInsensitive)
    ]
    private static let precedingCues: [String: NSRegularExpression] = [
        "JSON": #"формат(?:а|е|ом|у)?|схем(?:а|у|ы|е|ой)|парсим|распарсить"#,
        "Kotlin": #"языке|язык|языком|код\p{Zs}+на|переписать\p{Zs}+на"#,
        "Android": #"под|для\p{Zs}+платформы|платформ[а-яё]*|верси[а-яё]*\p{Zs}+для"#,
    ].mapValues { try! NSRegularExpression(pattern: #"\b(?:"# + $0 + #")\p{Zs}+\z"#, options: .caseInsensitive) }
    private static let companyCue = try? NSRegularExpression(pattern:
        #"\b(?:компани[яиюей]|компанией|компаний|корпораци[яиюей]|сервис(?:а|ом|у|е)?|платформ[аыуе]|платформой|банк(?:а|ом|у|е)?|вендор(?:а|ом|у|е)?|маркетплейс(?:а|ом|у|е)?|стартап(?:а|ом|у|е)?|company|vendor|platform)[ \u00A0]+\z"#,
        options: .caseInsensitive)
    private static let platformPreposition = try! NSRegularExpression(
        pattern: #"\b(?:в|на)[ \u00A0]+\z"#, options: .caseInsensitive)
    private static let sentenceBreaks = CharacterSet(charactersIn: ".!?…\n\r")
    private static let rereadSite = try! NSRegularExpression(pattern:
        #"(?<![\p{L}\p{M}\p{N}_/@\\\-‐‑])([а-яё]{2,8}(?:[-‐‑][а-яё]{2,5})?)[\p{Zs}\-‐‑]+(?:продукт|сегмент|рынок|рынк|направлени|модел|продаж)[а-яё]*(?![\p{L}\p{M}\p{N}_/@\\])"#,
        options: .caseInsensitive)
    private static let businessCue = try! NSRegularExpression(pattern:
        #"\b(?:бизнес[а-яё]*|коммерци[а-яё]*|предпринимател[а-яё]*|корпоративн[а-яё]*|розничн[а-яё]*|оптов[а-яё]*)\b"#,
        options: .caseInsensitive)

    private let personalTerms: [String]
    private let personalKeys: Set<String>
    private let personalSpokenKeys: Set<String>
    private let preferredSpellings: [String: String]
    private let preferredNumericSpellings: [String: Set<String>]
    private let personalFamilies: AbbreviationFamilies
    private let personalPhrases: NSRegularExpression?

    init(personalVocabulary: String) {
        personalTerms = VocabularyDictionary.entries(in: personalVocabulary).map(\.text)
        preferredSpellings = Dictionary(personalTerms.map { (Self.key($0), $0) },
                                       uniquingKeysWith: { first, _ in first })
        preferredNumericSpellings = Dictionary(grouping: personalTerms.compactMap { term in
            Self.canonicalNumericSpelling(term).map { (canonical: $0, personal: term) }
        }, by: \.canonical).mapValues { Set($0.map(\.personal)) }
        personalKeys = Set(personalTerms.flatMap { [$0] + RecognitionVocabulary.cyrillicInflections(of: $0) }.map(Self.key))
        personalSpokenKeys = Set(personalKeys.map(Self.spokenKey))
        personalFamilies = AbbreviationFamilies(personalVocabulary)
        let phrases = personalTerms.filter { $0.contains(where: \.isWhitespace) }.map { term in
            term.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\p{Zs}+"#)
        }
        personalPhrases = phrases.isEmpty ? nil : try? NSRegularExpression(pattern:
            #"(?<![\p{L}\p{M}\p{N}_])(?:"# + phrases.joined(separator: "|") + #")(?![\p{L}\p{M}\p{N}_])"#,
            options: .caseInsensitive)
    }

    func hasPersonalSpokenSpelling(_ spelling: String) -> Bool {
        personalSpokenKeys.contains(Self.spokenKey(spelling))
    }

    func personalPhraseRanges(in text: String) -> [NSRange] {
        personalPhrases?.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range) ?? []
    }

    func apply(to text: String) -> String {
        let replacements = matches(in: text, includeCompanies: false).filter { $0.replacement != nil }
        guard !replacements.isEmpty else { return text }
        let result = NSMutableString(string: text)
        for match in replacements.reversed() {
            if let replacement = match.replacement { result.replaceCharacters(in: match.range, with: replacement) }
        }
        return result as String
    }

    func matches(in text: String, includeCompanies: Bool = true, literalRanges: [NSRange]? = nil) -> [Match] {
        let fullRange = NSRange(text.startIndex..., in: text)
        let ns = text as NSString
        let protected = (literalRanges ?? TranscriptOrthography.literalRanges(in: text))
            + personalPhraseRanges(in: text)
        let tokens = Self.token.matches(in: text, range: fullRange).compactMap { match -> (Range<String.Index>, String)? in
            guard let range = Range(match.range, in: text) else { return nil }
            return (range, String(text[range]))
        }
        var found: [Match] = []
        var index = 0
        while index < tokens.count {
            let first = tokens[index].0.lowerBound
            let before = text[..<first].last
            guard before.map({ !Self.isWordCharacter($0) && !Self.attached.contains($0) && !Self.hyphens.contains($0) }) != false else {
                index += 1
                continue
            }
            let start = tokens[index].1.lowercased()
            var patterns = Self.index[start] ?? []
            if Self.mayHaveEnding(start) {
                for (stem, _) in Self.declinedForms(start) {
                    patterns += (Self.index[stem] ?? []).filter { $0.words.count == 1 && $0.inflectable }
                }
            }
            var choices: [(match: Match, width: Int, spoken: Bool)] = []
            for pattern in patterns {
                let lastIndex = index + pattern.words.count - 1
                guard lastIndex < tokens.count else { continue }
                let numericSpellings = preferredNumericSpellings[pattern.term] ?? []
                guard numericSpellings.count <= 1 else { continue }
                if pattern.personalOnly {
                    guard !numericSpellings.isEmpty,
                          !tokens[index...lastIndex].contains(where: { personalKeys.contains(Self.key($0.1)) }) else { continue }
                    let next = lastIndex + 1
                    if start.first?.isNumber == true, next < tokens.count,
                       Self.dataAmountNouns.contains(tokens[next].1.lowercased()),
                       Self.isSpokenGap(text[tokens[lastIndex].0.upperBound..<tokens[next].0.lowerBound]) { continue }
                }
                guard tokens[index..<lastIndex].map({ $0.1.lowercased() }).elementsEqual(pattern.words.dropLast()) else { continue }
                let lastToken = tokens[lastIndex].1.lowercased()
                let ending: String
                if lastToken == pattern.words.last {
                    ending = ""
                } else if pattern.inflectable, let suffix = Self.declinedForms(lastToken).first(where: { $0.0 == pattern.words.last })?.1 {
                    ending = suffix
                } else { continue }

                let last = tokens[lastIndex].0.upperBound
                let after = text[last...].first
                guard after.map({ !Self.isWordCharacter($0) && !Self.attached.contains($0) && !"+#&'’".contains($0) }) != false else { continue }
                let source = String(text[first..<last])
                let base = String(source.dropLast(ending.count)).trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
                if pattern.spoken {
                    let gaps = (index..<lastIndex).map { position in
                        text[tokens[position].0.upperBound..<tokens[position + 1].0.lowerBound]
                    }
                    guard gaps.allSatisfy(Self.isSpokenGap),
                          !hasPersonalSpokenSpelling(base) else { continue }
                } else if !Self.writtenMatch(base, spelling: pattern.spelling) { continue }

                let range = NSRange(first..<last, in: text)
                guard !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      !personalKeys.contains(Self.key(source)), !personalKeys.contains(Self.key(base)),
                      personalFamilies.known(source) == nil else { continue }
                guard !pattern.requiresContext || Self.hasCue(for: pattern.term, in: text, near: range, protecting: protected) else { continue }
                guard !pattern.requiresCompanyCue || Self.hasPrecedingCompanyCue(in: text, before: range, protecting: protected)
                    || (pattern.inflectable && ending == "е" && Self.hasPlatformPreposition(in: text, before: range, protecting: protected)) else { continue }
                // A personal entry chooses the spelling; it must not disable
                // the curated pronunciations and written aliases of that term.
                let term = numericSpellings.first ?? preferredSpellings[Self.key(pattern.term)] ?? pattern.term
                let canonical = ending.isEmpty ? term : term + "'" + ending
                let replacement = pattern.spoken || !ending.isEmpty || pattern.spelling != pattern.term ? canonical : nil
                let match = Match(term: term, range: range, ending: ending, replacement: replacement)
                choices.append((match, pattern.words.count, pattern.spoken))
            }
            if let longest = choices.max(by: { $0.match.range.length < $1.match.range.length }) {
                let sameSpan = choices.filter { $0.match.range.length == longest.match.range.length }
                let written = sameSpan.filter { !$0.spoken }
                let preferred = written.isEmpty ? sameSpan : written
                // An exact pronunciation wins over a shorter alias plus a
                // guessed suffix: пи оу is PO, not пи о + the ending у.
                let exact = preferred.filter { $0.match.ending.isEmpty }
                let resolved = exact.isEmpty ? preferred : exact
                if Set(resolved.map { $0.match.term }).count == 1, let choice = resolved.first {
                    found.append(choice.match)
                    index += choice.width
                    continue
                }
            }
            index += 1
        }
        guard includeCompanies else { return found }
        let companyMatches = TechnologyCompanyVocabulary.matches(in: text, protecting: protected + found.map(\.range))
            .filter { match in
                !personalKeys.contains(Self.key(match.term)) && !personalKeys.contains(Self.key(ns.substring(with: match.range)))
                    && personalFamilies.known(ns.substring(with: match.range)) == nil
            }.map { Match(term: $0.term, range: $0.range, ending: "", replacement: $0.replacement) }
        return (found + companyMatches).sorted { $0.range.location < $1.range.location }
    }

    func observedTerms(in texts: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for text in texts {
            for match in matches(in: text)
            where preferredSpellings[Self.key(match.term)] == nil && seen.insert(Self.key(match.term)).inserted {
                terms.append(match.term)
                if terms.count == limit { return terms }
            }
        }
        return terms
    }

    /// Only a fresh decode may use this suggestion. The visible text and the
    /// meeting term index still require an exact spoken or written match.
    func rereadHint(in text: String) -> (term: String, range: Range<String.Index>)? {
        let full = NSRange(text.startIndex..., in: text)
        let sites = Self.rereadSite.matches(in: text, range: full)
        guard !sites.isEmpty else { return nil }
        let literals = TranscriptOrthography.literalRanges(in: text)
        let protected = literals + (personalPhrases?.matches(in: text, range: full).map(\.range) ?? [])
        let cues = Self.businessCue.matches(in: text, range: full).filter { cue in
            !literals.contains { NSIntersectionRange($0, cue.range).length > 0 }
        }
        guard !cues.isEmpty else { return nil }
        let known = matches(in: text, includeCompanies: false)
        var found: (term: String, range: Range<String.Index>)?
        for site in sites {
            let span = site.range(at: 1)
            guard let range = Range(span, in: text),
                  !protected.contains(where: { NSIntersectionRange($0, site.range).length > 0 }),
                  !known.contains(where: { NSIntersectionRange($0.range, span).length > 0 }),
                  cues.contains(where: { abs($0.range.location - span.location) <= 90 }) else { continue }
            let source = String(text[range])
            let key = Self.spokenKey(source)
            guard key.count >= 5, !personalSpokenKeys.contains(key) else { continue }
            let phonetic = key.filter { $0 != "ь" && $0 != "ъ" }
            let trailing = source.lowercased().split { Self.hyphens.contains($0) }.dropFirst().last
            let candidates = Self.numericRereadPhonetics.compactMap { term, forms -> (String, Int)? in
                guard !personalKeys.contains(Self.key(term)), personalSpokenKeys.isDisjoint(with: forms) else { return nil }
                let distance = forms.filter { $0.first == phonetic.first }.map { SpokenVocabulary.distance(phonetic, $0) }.min()
                guard let distance else { return nil }
                if distance > 0 {
                    guard distance <= 2, let trailing, let letter = term.last, let pronunciation = Self.letterNames[letter],
                          trailing.hasPrefix(pronunciation) else { return nil }
                }
                return (term, distance)
            }.sorted { $0.1 < $1.1 }
            guard let best = candidates.first, candidates.dropFirst().first?.1 != best.1 else { continue }
            // Only a single localized site is safe to send to the verifier.
            guard found == nil else { return nil }
            found = (best.0, range)
        }
        return found
    }

    static func isCanonical(_ term: String) -> Bool {
        (index[words(in: term).first ?? ""] ?? []).contains { $0.term == term }
            || TechnologyCompanyVocabulary.isCanonical(term)
    }

    static func canonicalNumericSpelling(_ term: String) -> String? {
        guard term.first?.isNumber == true, AbbreviationFamilies.isBase(term) else { return nil }
        return index[key(term)]?.first { !$0.spoken && $0.spelling == term }.map(\.term)
    }

    static func supportsEndings(for term: String) -> Bool {
        inflectableKeys.contains(key(term))
    }

    static func isHiddenFromCandidates(_ term: String) -> Bool {
        hiddenCandidateKeys.contains(key(term))
    }

    private static let hiddenCandidateKeys: Set<String> = Set(
        TechnologyVocabularyCatalog.entries.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count > 1, fields[1].contains("h") else { return nil }
            return key(String(fields[0]))
        })

    /// Curated homonyms need their own context and ending rules even when the
    /// user has saved the canonical brand spelling in their dictionary.
    static func requiresCompanyContext(_ term: String) -> Bool {
        contextualCompanyKeys.contains(key(term))
    }

    private static let contextualCompanyKeys: Set<String> = Set(
        TechnologyVocabularyCatalog.entries.split(whereSeparator: \.isNewline).compactMap { (line: Substring) -> String? in
            let fields: [Substring] = line.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count > 1, fields[1].contains("i"), fields[1].contains("c") else { return nil }
            return key(String(fields[0]))
        })

    private static let inflectableKeys: Set<String> = Set(
        TechnologyVocabularyCatalog.entries.split(whereSeparator: \.isNewline).compactMap { (line: Substring) -> String? in
            let fields: [Substring] = line.split(separator: "|", omittingEmptySubsequences: false)
            guard let term = fields.first, AbbreviationFamilies.isBase(String(term))
                || (fields.count > 1 && fields[1].contains("i")) else { return nil }
            return key(String(term))
        })

    private static func key(_ text: String) -> String {
        AbbreviationFamilies.key(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func mayHaveEnding(_ word: String) -> Bool {
        word.count >= 3 && word.last.map { "аеёиоуыэюямхвйк".contains($0) } == true
    }

    private static func declinedForms(_ word: String) -> [(String, String)] {
        if let apostrophe = word.lastIndex(where: { $0 == "'" || $0 == "’" }) {
            let ending = String(word[word.index(after: apostrophe)...])
            return russianEndings.contains(ending) ? [(String(word[..<apostrophe]), ending)] : []
        }
        return endings.compactMap { ending in
            guard word.count > ending.count, word.hasSuffix(ending) else { return nil }
            return (String(word.dropLast(ending.count)), ending)
        }
    }

    private static func writtenMatch(_ source: String, spelling: String) -> Bool {
        guard !source.contains(where: \.isNewline) else { return false }
        let flattened = source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return spelling.contains(" ") && spelling == spelling.lowercased()
            ? flattened.lowercased() == spelling : flattened == spelling
    }

    private static func hasCue(for term: String, in text: String, near range: NSRange, protecting protected: [NSRange]) -> Bool {
        let ns = text as NSString
        let left = ns.rangeOfCharacter(from: sentenceBreaks, options: .backwards, range: NSRange(location: 0, length: range.location))
        let start = max(left.location == NSNotFound ? 0 : NSMaxRange(left), range.location - 72)
        let preceding = NSRange(location: start, length: range.location - start)
        var cues = precedingCues[term]?.matches(in: text, range: preceding) ?? []
        if let nearbyCue = nearbyCues[term] {
            let right = ns.rangeOfCharacter(from: sentenceBreaks, options: [],
                range: NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range)))
            let end = min(right.location == NSNotFound ? ns.length : right.location, NSMaxRange(range) + 72)
            cues = nearbyCue.matches(in: text, range: NSRange(location: start, length: end - start))
        }
        return cues.contains { cue in
            (protected + [range]).allSatisfy { NSIntersectionRange($0, cue.range).length == 0 }
        }
    }

    static func hasPrecedingCompanyCue(in text: String, before range: NSRange, protecting protected: [NSRange]) -> Bool {
        let start = max(0, range.location - 32)
        guard let cue = companyCue?.firstMatch(in: text, range: NSRange(location: start, length: range.location - start)) else { return false }
        return !protected.contains { NSIntersectionRange($0, cue.range).length > 0 }
    }

    private static func hasPlatformPreposition(in text: String, before range: NSRange, protecting protected: [NSRange]) -> Bool {
        let start = max(0, range.location - 12)
        guard let cue = platformPreposition.firstMatch(in: text, range: NSRange(location: start, length: range.location - start)) else { return false }
        return !protected.contains { NSIntersectionRange($0, cue.range).length > 0 }
    }

    private static func spokenSeparator(_ character: Character) -> Bool {
        (!character.isNewline && character.isWhitespace) || hyphens.contains(character)
    }

    private static func isSpokenGap(_ gap: Substring) -> Bool {
        !gap.isEmpty && (gap.allSatisfy { $0.isWhitespace && !$0.isNewline }
            || (gap.count == 1 && gap.first.map(hyphens.contains) == true))
    }

    private static let letterNames: [Character: String] = [
        "A": "эй", "B": "би", "C": "си", "D": "ди", "E": "и", "F": "эф", "G": "джи", "H": "эйч", "I": "ай",
        "J": "джей", "K": "кей", "L": "эл", "M": "эм", "N": "эн", "O": "оу", "P": "пи", "Q": "кью", "R": "ар",
        "S": "эс", "T": "ти", "U": "ю", "V": "ви", "W": "дабл ю", "X": "икс", "Y": "вай", "Z": "зет", "2": "ту"
    ]

    private static func words(in spelling: String) -> [String] {
        let ns = spelling as NSString
        return token.matches(in: spelling, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
    }

    /// Produce fused, spaced and partly fused forms from verified syllables.
    private static func spellings(for syllables: [String]) -> [[String]] {
        guard let first = syllables.first else { return [] }
        return syllables.dropFirst().reduce([[first]]) { prefixes, next in
            prefixes.flatMap { prefix in [prefix + [next], Array(prefix.dropLast()) + [prefix.last! + next]] }
        }
    }

    private static func spokenKey(_ text: String) -> String { key(text).filter { !spokenSeparator($0) } }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character.unicodeScalars.contains {
            CharacterSet.nonBaseCharacters.contains($0)
        }
    }

    private static let numericRereadPhonetics: [String: Set<String>] = {
        var result: [String: Set<String>] = [:]
        for patterns in index.values {
            for pattern in patterns where pattern.spoken && pattern.term.count == 3 && pattern.term.dropFirst().first == "2" {
                let joined = pattern.words.joined()
                guard joined.unicodeScalars.allSatisfy({ (0x430...0x44F).contains($0.value) || $0.value == 0x451 }) else { continue }
                result[pattern.term, default: []].insert(joined)
            }
        }
        return result
    }()

    private static let index: [String: [Pattern]] = {
        var result: [String: [Pattern]] = [:]
        for line in TechnologyVocabularyCatalog.entries.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let term = fields[0]
            let mode = fields.count > 1 ? fields[1] : ""
            let inflectable = AbbreviationFamilies.isBase(term) || mode.contains("i")
            let aliases = fields.count > 2 ? fields[2].split(separator: ";").map(String.init) : []
            var spoken = aliases.filter { !$0.hasPrefix("=") }.map { alias in
                let personalOnly = alias.hasPrefix("~")
                let text = personalOnly ? String(alias.dropFirst()) : alias
                return (syllables: text.split(separator: " ").map(String.init), personalOnly: personalOnly)
            }
            if mode == "+" {
                let letters = term.compactMap { letterNames[$0] }
                if letters.count == term.count {
                    spoken.append((letters.flatMap { $0.split(separator: " ").map(String.init) }, false))
                }
            }
            var patterns = ([term] + aliases.filter { $0.hasPrefix("=") }.map { String($0.dropFirst()) }).map { spelling in
                Pattern(term: term, words: words(in: spelling), spelling: spelling, spoken: false, personalOnly: false,
                        requiresContext: false, requiresCompanyCue: mode.contains("c") && spelledLikeAlias(spelling, spoken.map(\.syllables)),
                        inflectable: inflectable)
            }
            var seen = Set<[String]>()
            for (syllables, personalOnly) in spoken where syllables.count <= 8 {
                for spelling in spellings(for: syllables) where seen.insert(spelling).inserted {
                    patterns.append(Pattern(term: term, words: spelling, spelling: "", spoken: true, personalOnly: personalOnly,
                                            requiresContext: mode == "?" || (mode == "w" && syllables.joined().allSatisfy(\.isASCII)),
                                            requiresCompanyCue: mode.contains("c"),
                                            inflectable: inflectable))
                }
            }
            for pattern in patterns {
                if let first = pattern.words.first { result[first, default: []].append(pattern) }
            }
        }
        return result
    }()

    private static func spelledLikeAlias(_ spelling: String, _ aliases: [[String]]) -> Bool {
        aliases.contains { $0.joined().lowercased() == spokenKey(spelling) }
    }
}
