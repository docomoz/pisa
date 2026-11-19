import Foundation

/// A local, indexed directory of company spellings. Bulk source labels can
/// nominate an audio hint or a term; they never authorize automatic replacement.
enum TechnologyCompanyVocabulary {
    private struct Catalog: Decodable {
        let entries: [Entry]
    }
    private struct Entry: Decodable {
        let id: String
        let term: String
        let aliases: [Alias]
    }
    private struct Alias: Decodable {
        let text: String
        let contextRequired: Bool
    }
    private struct IndexedAlias {
        let term: String
        let text: String
        let keys: [String]
        let contextRequired: Bool
    }
    private static let token = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{M}\p{N}.&+'’‐‑-]*"#)
    private static let cues: Set<String> = [
        "компания", "компании", "компанию", "компанией", "компаний", "сервис", "сервиса", "сервисом",
        "платформа", "платформы", "платформу", "платформой", "разработчик", "разработчика", "разработчики",
        "производитель", "производителя", "поставщик", "поставщика", "вендор", "вендора", "стартап", "стартапа",
        "корпорация", "корпорации", "company", "corporation", "vendor", "startup", "platform", "inc", "ltd"
    ]
    private static let catalog: [Entry] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "PisaTechnologyCompanies", withExtension: "deflate"),
              let compressed = NSData(contentsOf: url),
              let data = try? compressed.decompressed(using: .zlib),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: Data(referencing: data)) else { return [] }
        return catalog.entries
    }()
    static var entryCount: Int { catalog.count }
    private static let canonicalTerms = Set(catalog.map(\.term))
    static func isCanonical(_ term: String) -> Bool { canonicalTerms.contains(term) }
    private static let index: [String: [IndexedAlias]] = {
        var aliases: [String: [IndexedAlias]] = [:]
        for entry in catalog {
            for alias in entry.aliases {
                let keys = tokens(alias.text).map { key($0.text) }
                guard !keys.isEmpty, keys.count <= 6 else { continue }
                let joined = keys.joined(separator: " ")
                aliases[joined, default: []].append(IndexedAlias(term: entry.term, text: alias.text,
                    keys: keys, contextRequired: alias.contextRequired))
            }
        }
        var result: [String: [IndexedAlias]] = [:]
        for matches in aliases.values {
            // Homonymous labels of different companies cannot choose a name.
            guard Set(matches.map { key($0.term) }).count == 1 else { continue }
            var seen: Set<String> = []
            for alias in matches where seen.insert(alias.text).inserted {
                result[alias.keys[0], default: []].append(alias)
            }
        }
        return result.mapValues { $0.sorted { $0.keys.count > $1.keys.count } }
    }()

    static func matches(in text: String, protecting ranges: [NSRange]) -> [(term: String, range: NSRange, replacement: String?)] {
        let words = tokens(text), ns = text as NSString
        let keys = words.map { key($0.text) }
        let protected = ranges + TranscriptOrthography.literalRanges(in: text)
        var found: [(term: String, range: NSRange, replacement: String?)] = []
        for (position, word) in words.enumerated() {
            for alias in index[keys[position]] ?? [] {
                let end = position + alias.keys.count
                guard end <= words.count, Array(keys[position..<end]) == alias.keys else { continue }
                let range = NSRange(location: word.range.location,
                    length: NSMaxRange(words[end - 1].range) - word.range.location)
                guard !(protected + found.map(\.range)).contains(where: { NSIntersectionRange($0, range).length > 0 }),
                      let swiftRange = Range(range, in: text),
                      text[..<swiftRange.lowerBound].last.map({ !$0.isLetter && !$0.isNumber && !"_/@\\".contains($0) }) ?? true,
                      text[swiftRange.upperBound...].first.map({ !$0.isLetter && !$0.isNumber && !"_/@\\".contains($0) }) ?? true else { continue }
                let source = ns.substring(with: range)
                // Match the literal spelling, including punctuation, and require
                // its case. Phonetic/caseless aliases belong to the curated layer.
                guard source == alias.text else { continue }
                // A title-cased ordinary phrase can also be a catalog alias.
                // Its words alone do not identify the company.
                if alias.contextRequired || (alias.keys.count > 1 && alias.keys.allSatisfy(TranscriptTerms.isCommonRussianWord)) {
                    let lower = max(0, position - 3), upper = min(words.count, end + 3)
                    guard (lower..<upper).contains(where: { cue in
                        guard (cue < position || cue >= end) && cues.contains(keys[cue]),
                              !protected.contains(where: { NSIntersectionRange($0, words[cue].range).length > 0 }) else { return false }
                        let start = cue < position ? NSMaxRange(words[cue].range) : NSMaxRange(range)
                        let finish = cue < position ? range.location : words[cue].range.location
                        let gap = ns.substring(with: NSRange(location: start, length: finish - start))
                        return !gap.contains(where: { ".!?;\n\r".contains($0) })
                    }) else { continue }
                }
                found.append((alias.term, range, nil))
                break
            }
        }
        return found
    }

    private static func tokens(_ text: String) -> [(text: String, range: NSRange)] {
        let ns = text as NSString
        return token.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            var range = match.range
            // Sentence punctuation is not part of a company spelling.
            while range.length > 0, ".'’‐‑-".contains(ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1))) {
                range.length -= 1
            }
            return (ns.substring(with: range), range)
        }
    }
    private static func key(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
    }
}
