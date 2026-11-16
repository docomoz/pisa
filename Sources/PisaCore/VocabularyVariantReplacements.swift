import Foundation

/// Applies the user's explicitly linked spellings to recognized text.
struct VocabularyVariantReplacements {
    private let canonicalByVariant: [String: String]
    private let expression: NSRegularExpression?

    init(_ variants: [String: [String]], vocabulary: String) {
        let canonicalByKey = Dictionary(
            VocabularyDictionary.entries(in: vocabulary).map { (VocabularyDictionary.literalKey($0.text), $0.text) },
            uniquingKeysWith: { first, _ in first }
        )
        var targets: [String: Set<String>] = [:]
        for (term, forms) in variants {
            guard let canonical = canonicalByKey[VocabularyDictionary.literalKey(term)] else { continue }
            for form in forms {
                let key = VocabularyDictionary.literalKey(form)
                guard !key.isEmpty, canonicalByKey[key] == nil else { continue }
                targets[key, default: []].insert(canonical)
            }
        }
        canonicalByVariant = targets.compactMapValues { $0.count == 1 ? $0.first : nil }
        let alternatives = canonicalByVariant.keys.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0 < $1
        }.map { form in
            form.split(separator: " ").map { word in
                word.components(separatedBy: "'")
                    .map(NSRegularExpression.escapedPattern(for:))
                    .joined(separator: "['’]")
            }.joined(separator: #"[\p{Zs}\t]+"#)
        }
        guard !alternatives.isEmpty else {
            expression = nil
            return
        }
        let connected = #"[\p{L}\p{M}\p{N}_/\\@&+\-‐‑]"#
        let leading = #"(?<!\#(connected))(?<![\p{L}\p{M}\p{N}]['’])"#
        let trailing = #"(?!\#(connected))(?!['’][\p{L}\p{M}\p{N}])"#
        expression = try? NSRegularExpression(
            pattern: leading + "(?:" + alternatives.joined(separator: "|") + ")" + trailing,
            options: .caseInsensitive
        )
    }

    func apply(to text: String) -> String {
        guard let expression else { return text }
        let source = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return text }
        let protected = TranscriptOrthography.literalRanges(in: text)
        let result = NSMutableString(string: text)
        for match in matches.reversed() {
            guard !protected.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  let canonical = canonicalByVariant[VocabularyDictionary.literalKey(source.substring(with: match.range))]
            else { continue }
            result.replaceCharacters(in: match.range, with: canonical)
        }
        return result as String
    }
}
