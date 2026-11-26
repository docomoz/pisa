import Foundation

public enum TranscriptOrthography {
    // The context-free dictionary contains only unambiguous forms.
    private static let fallbackYoSpellings = Dictionary(uniqueKeysWithValues: [
        "ещё", "даёшь", "даёт", "даём", "даёте", "даётся",
        "идёшь", "идёт", "идём", "идёте", "придёшь", "придёт", "придём", "придёте",
        "пойдёшь", "пойдёт", "пойдём", "пойдёте", "живёшь", "живёт", "живём", "живёте",
        "учёт", "учёта", "учёту", "учётом", "учёте",
        "отчёт", "отчёта", "отчёту", "отчётом", "отчёте", "отчёты", "отчётов", "отчётам", "отчётами", "отчётах",
        "расчёт", "расчёта", "расчёту", "расчётом", "расчёте", "расчёты", "расчётов", "расчётам", "расчётами", "расчётах",
    ].map { ($0.replacingOccurrences(of: "ё", with: "е"), $0) })

    private static let yoSpellings: [String: String] = {
        guard let url = yoWordformsURL(), let compressed = NSData(contentsOf: url),
              let data = try? compressed.decompressed(using: .zlib),
              let text = String(data: data as Data, encoding: .utf8), !text.isEmpty else { return fallbackYoSpellings }
        let forms = text.split(separator: "\n")
        var result = [String: String](minimumCapacity: forms.count)
        for form in forms {
            let canonical = String(form)
            result[canonical.replacingOccurrences(of: "ё", with: "е")] = canonical
        }
        return result
    }()

    private static func yoWordformsURL() -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "PisaYoWords", withExtension: "deflate")
        #else
        return Bundle.main.url(forResource: "PisaYoWords", withExtension: "deflate")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/PisaYoWords.deflate")
        #endif
    }

    private static let candidates: NSRegularExpression = {
        let separator = #"(?:\p{Zs}+|\p{Zs}*[-‐‑]\p{Zs}*)"#
        let focus = "(?:focus|фокус)" + separator + "(групп(?:ами|ах|ам|ою|ой|а|ы|е|у)?)"
        let idea = "(иде(?:ями|ях|ям|ей|ею|я|и|е|ю|й))" + separator + "(?:fix|фикс)"
        let yo = "([а-яё]*е[а-яё]*)"
        let filler = "(uh" + separator + "huh|mm" + separator + "hmm|uhhuh|uhum|hmm|hm|mmhmm|mhm|uh|huh|um|ah|ajá|yeah|yep|yes|ok|okay)"
        let alternatives = [focus, idea, "sorry|сори", yo, filler].joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}_/\\@])(?:"# + alternatives + #")(?![\p{L}\p{N}_/\\@])"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private struct YoContext {
        let spelling: String
        let before: NSRegularExpression?
        let after: NSRegularExpression?

        init(_ spelling: String, before: String? = nil, after: String? = nil) {
            self.spelling = spelling
            self.before = before.map {
                try! NSRegularExpression(pattern: #"(?i)(?<![\p{L}\p{N}_])(?:"# + $0 + #")\h+$"#)
            }
            self.after = after.map {
                try! NSRegularExpression(pattern: #"(?i)^(?:"# + $0 + ")")
            }
        }

        func matches(before preceding: String, after following: String) -> Bool {
            func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
                guard let pattern else { return true }
                return pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            }
            return matches(before, preceding) && matches(after, following)
        }
    }

    private static let contextualYoSpellings: [String: [YoContext]] = [
        "все": [
            YoContext("всё", before: #"вот\h+(?:это|и)|на\h+этом|это|и"#, after: #"\h*$"#),
            YoContext("всё", after: #"[-‐‑]таки\b|\h+(?:остальное|готово|сделано|получилось|закончилось|началось|работает)\b"#),
            YoContext("всё", after: #"\h+(?:ясно|понятно|нормально|хорошо|правильно|отлично)\h*(?=$|[,;:—–])"#),
            YoContext("всё", before: "я|ты|он|она|оно", after: #"\h+ещ[её]\b"#),
            YoContext("всё", before: "мне|тебе|ему|ей|нам|вам|им", after: #"\h+равно\b"#),
        ],
        "черт": [YoContext("чёрт", after: #"\h+(?:с\h+(?:ним|ней|ними|тобой|вами|этим)|(?:его\h+)?знает|побери|возьми)\b"#)],
        "нее": [YoContext("неё", before: "у|для|из|от|до|без|из-за|возле|вокруг|около|на|про|за|в|через|под")],
        "чем": [YoContext("чём", before: "о|об|в|на|при")],
        "берет": [YoContext("берёт", after: #"\h+(?:на\h+себя|в\h+работу|под\h+контроль)\b"#)],
    ]

    // A hyphen only counts as punctuation when separated from words. An en or
    // figure dash can also be a numeric range separator or a signed number.
    private static let dashes = try! NSRegularExpression(pattern:
        #"(?m)\p{N}\h*[-‐‑–‒]\h*(?=[+−-]?\p{N})|(?<![\p{L}\p{N}])[–‒](?=\p{N})|([–‒―]|(?:^|(?<=\h))[-‐‑]{1,2}(?=\h|$)|(?<=\p{L})--(?=\p{L}))"#)

    // Each protected form starts with a quote/fence or contains one of these
    // link markers. Ordinary turns can skip the more expensive full matcher.
    private static let literalCue = try! NSRegularExpression(pattern:
        #"["«“‘`@]|(?<![\p{L}\p{N}])'|~~~|://|(?i:mailto:)|\.(?=\S)"#)
    private static let quotedOrLinked = try! NSRegularExpression(pattern:
        #"(?i)(?m:^[\t ]{0,3}((`|~)\2{2,})(?!\2)[^\r\n]*\R[\s\S]*?^[\t ]{0,3}\1\2*[\t ]*(?=\r?$))|(?<!`)(`+)(?!`)[\s\S]*?(?<!`)\3(?!`)|"[^"\r\n]*"|(?<![\p{L}\p{N}])'[^'\r\n]*'(?![\p{L}\p{N}])|«[^»]*»|“[^”]*”|‘[^’]*’|\b(?:[a-z][a-z0-9+.-]*://|www\.|mailto:)\S+|[\p{L}\p{N}_.+%'-]+@[\p{L}\p{N}.-]+|(?:[\p{L}\p{N}-]+\.)+[\p{L}]{2,}(?:[/#?]\S*)?"#)
    private static let sentenceBreaks = CharacterSet(charactersIn: ".!?…\n\r")

    static func literalRanges(in text: String) -> [NSRange] {
        let range = NSRange(text.startIndex..., in: text)
        guard literalCue.firstMatch(in: text, range: range) != nil else { return [] }
        return quotedOrLinked.matches(in: text, range: range).map(\.range)
    }

    public static func normalize(_ text: String, vocabulary: String = "") -> String {
        normalizeDashes(in: normalizeSpelling(in: text, vocabulary: vocabulary), vocabulary: vocabulary)
    }

    private static func normalizeSpelling(in text: String, vocabulary: String) -> String {
        let phrases = glossaryRanges(in: text, vocabulary: vocabulary, range: NSRange(text.startIndex..., in: text), minimumWordCount: 2)
        let text = AbbreviationFamilies(vocabulary).normalize(in: text, includeInferred: true, protecting: phrases)
        let entireText = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = candidates.matches(in: text, range: entireText).filter { match in
            guard let word = Range(match.range(at: 3), in: text) else { return true }
            return yoSpelling(for: text[word]) != nil || contextualYoSpellings[text[word].lowercased()] != nil
        }
        guard !matches.isEmpty else { return text }
        let quoted = literalRanges(in: text)
        let protected = quoted + glossaryRanges(in: text, vocabulary: vocabulary, range: entireText)
        let editable = matches.filter { match in
            !protected.contains { NSIntersectionRange($0, match.range).length > 0 }
        }
        let source = text as NSString
        let evidence = NSMutableString(string: text)
        for range in quoted { mask(range, in: evidence) }

        // Use the same language evidence before and after compound spelling
        // changes. Quoted text and the spelling being decided cannot vote.
        var isolatedFillers: Set<Int> = []
        for match in editable {
            let group = match.range(at: 1)
            let idea = match.range(at: 2)
            if group.location != NSNotFound {
                mask(NSRange(location: match.range.location, length: group.location - match.range.location), in: evidence)
            } else if idea.location != NSNotFound {
                mask(NSRange(location: NSMaxRange(idea), length: NSMaxRange(match.range) - NSMaxRange(idea)), in: evidence)
            } else if match.range(at: 4).location != NSNotFound {
                let context = sentenceContext(around: match.range, source: source, evidence: evidence)
                if isIsolatedFiller(before: context.before, after: context.after)
                    || isLeadingVocalization(source.substring(with: match.range), before: context.before, after: context.after) {
                    isolatedFillers.insert(match.range.location)
                    mask(match.range, in: evidence)
                }
            } else if match.range(at: 3).location == NSNotFound {
                mask(match.range, in: evidence)
            }
        }

        let result = NSMutableString(string: text)
        for match in editable.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            if match.range(at: 3).location != NSNotFound {
                let word = text[range]
                var spelling = yoSpelling(for: word)
                if spelling == nil, let rules = contextualYoSpellings[word.lowercased()] {
                    let context = sentenceContext(around: match.range, source: source, evidence: evidence)
                    spelling = rules.first { $0.matches(before: context.before, after: context.after) }?.spelling
                }
                guard let spelling else { continue }
                let revised = zip(word, spelling).map { original, canonical in
                    canonical == "ё" ? (original.isUppercase ? "Ё" : "ё") : original
                }
                result.replaceCharacters(in: match.range, with: String(revised))
                continue
            }
            let context = sentenceContext(around: match.range, source: source, evidence: evidence)
            let words = RussianRecognition.words(evidence.substring(with: context.range))
            let cyrillic = words.filter { $0.unicodeScalars.allSatisfy { (0x0430...0x044F).contains($0.value) } }.count
            let latin = words.filter { $0.unicodeScalars.allSatisfy { (0x61...0x7A).contains($0.value) } }.count
            guard cyrillic > latin else { continue }
            let capitalize = !context.before.contains(where: \.isLetter)
            let spelling: String
            if let group = Range(match.range(at: 1), in: text) {
                guard RussianRecognition.words(context.before).last != "ford" else { continue }
                spelling = "фокус-" + text[group].lowercased()
            } else if let idea = Range(match.range(at: 2), in: text) {
                // Match the requested transcript spelling of this expression.
                spelling = text[idea].lowercased() + "-фикс"
            } else if match.range(at: 4).location != NSNotFound {
                guard isolatedFillers.contains(match.range.location),
                      let russian = BackchannelLanguage.russianSpelling(ofFiller: String(text[range])) else { continue }
                spelling = russian
            } else {
                if text[range].lowercased() == "сори" {
                    guard isIsolatedFiller(before: context.before, after: context.after) else { continue }
                }
                spelling = "сорри"
            }
            result.replaceCharacters(in: match.range, with: capitalize ? spelling.prefix(1).uppercased() + spelling.dropFirst() : spelling)
        }
        return result as String
    }

    private static func normalizeDashes(in text: String, vocabulary: String) -> String {
        let full = NSRange(text.startIndex..., in: text)
        let matches = dashes.matches(in: text, range: full).map { $0.range(at: 1) }.filter { $0.location != NSNotFound }
        guard !matches.isEmpty else { return text }
        let protected = literalRanges(in: text) + glossaryRanges(in: text, vocabulary: vocabulary, range: full, minimumWordCount: 2)
        let result = NSMutableString(string: text)
        for range in matches.reversed() where !protected.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
            result.replaceCharacters(in: range, with: "—")
        }
        return result as String
    }

    static func yoSpelling(for word: Substring) -> String? {
        let lower = word.lowercased()
        guard lower.contains("ё") else { return yoSpellings[lower] }
        guard let canonical = yoSpellings[lower.replacingOccurrences(of: "ё", with: "е")], canonical != lower,
              !zip(lower, canonical).contains(where: { $0 == "ё" && $1 != "ё" }) else { return nil }
        return canonical
    }

    private static func mask(_ range: NSRange, in text: NSMutableString) {
        text.replaceCharacters(in: range, with: String(repeating: " ", count: range.length))
    }

    private static func sentenceContext(around match: NSRange, source: NSString, evidence: NSString) -> (range: NSRange, before: String, after: String) {
        let endOfMatch = NSMaxRange(match)
        let left = evidence.rangeOfCharacter(from: sentenceBreaks, options: .backwards, range: NSRange(location: 0, length: match.location))
        let right = evidence.rangeOfCharacter(from: sentenceBreaks, range: NSRange(location: endOfMatch, length: source.length - endOfMatch))
        let start = left.location == NSNotFound ? 0 : NSMaxRange(left)
        let end = right.location == NSNotFound ? source.length : right.location
        return (NSRange(location: start, length: end - start),
                source.substring(with: NSRange(location: start, length: match.location - start)),
                source.substring(with: NSRange(location: endOfMatch, length: end - endOfMatch)))
    }

    private static func isIsolatedFiller(before: String, after: String) -> Bool {
        let leading = before.last { !$0.isWhitespace }
        let trailing = after.first { !$0.isWhitespace }
        // A preceding word can make "Yes" in "слушаю Yes, ..." a name.
        return (!before.contains(where: \.isLetter) && trailing == ",")
            || (leading == "," && (trailing == "," || trailing == nil))
    }

    private static func isLeadingVocalization(_ word: String, before: String, after: String) -> Bool {
        guard before.allSatisfy(\.isWhitespace), after.first?.isWhitespace == true,
              BackchannelLanguage.isVocalization(word) else { return false }
        let following = RussianRecognition.words(after).prefix(2)
        return following.count == 2 && following.contains { $0.count >= 4 }
            && following.allSatisfy(TranscriptTerms.isCommonRussianWord)
    }

    static func glossaryRanges(in text: String, vocabulary: String, range: NSRange, minimumWordCount: Int = 1) -> [NSRange] {
        let terms = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(RussianRecognition.words).filter { $0.count >= minimumWordCount }
        guard !terms.isEmpty else { return [] }
        let alternatives = terms.map { words in
            words.map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "е", with: "[её]") }
                .joined(separator: #"[^\p{L}\p{N}]+"#)
        }.sorted { $0.count > $1.count }.joined(separator: "|")
        let pattern = #"(?i)(?=(?<![\p{L}\p{N}])("# + alternatives + #")(?![\p{L}\p{N}]))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: range).map { $0.range(at: 1) }
    }
}
