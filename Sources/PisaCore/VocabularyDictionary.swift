import Foundation

/// Range-based changes keep the user's original separators and surrounding text intact.
public enum VocabularyDictionary {
    private static let separators = CharacterSet(charactersIn: ",;\r\n")

    public struct Entry: Identifiable, Equatable, Sendable {
        public let text: String
        public var id: Int { range.location }
        fileprivate let source: String
        fileprivate let range: NSRange
    }

    public struct Batch: Sendable {
        public let additions: [String]
        public let duplicates: [String]
        public let invalid: [String]
        public let emptyCount: Int
        public let vocabulary: String
    }

    public struct Removal: Sendable {
        public let vocabulary: String
        public let variants: [String: [String]]
        private let range: NSRange
        private let removed: String
        private let removedVariants: [String]

        fileprivate init(vocabulary: String, variants: [String: [String]], range: NSRange,
                         removed: String, removedVariants: [String]) {
            self.vocabulary = vocabulary
            self.variants = variants
            self.range = range
            self.removed = removed
            self.removedVariants = removedVariants
        }

        public func restoring(in current: String) throws -> String {
            // The shared add operation replaces a whitespace-only dictionary with
            // the first term. Restore its original spacing before those new terms.
            if !vocabulary.isEmpty,
               vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !current.utf8.starts(with: vocabulary.utf8),
               !VocabularyDictionary.entries(in: current).isEmpty {
                let restored = NSMutableString(string: vocabulary)
                restored.insert(removed, at: range.location)
                return (restored as String) + "\n" + current
            }
            try VocabularyDictionary.requireSnapshot(vocabulary, in: current)
            let result = NSMutableString(string: current)
            // A sole removed entry leaves an empty string. A new addition then has no
            // separator; insert one so undo cannot accidentally join the two terms.
            let needsSeparator = range.location == (vocabulary as NSString).length &&
                current.utf8.count > vocabulary.utf8.count &&
                !VocabularyDictionary.startsWithSeparator(String(current.dropFirst(vocabulary.count))) &&
                !VocabularyDictionary.endsWithSeparator(removed)
            result.insert(removed + (needsSeparator ? "\n" : ""), at: range.location)
            return result as String
        }

        public func restoring(in current: String, variants: [String: [String]]) throws
            -> (vocabulary: String, variants: [String: [String]]) {
            let restored = try restoring(in: current)
            let forms = variants[removed, default: []] + removedVariants
            return (restored, try VocabularyDictionary.updatingVariants(forms, for: removed,
                                                                        in: restored, variants: variants))
        }
    }

    public enum Failure: LocalizedError {
        case empty, invalid, duplicate, stale
        case emptyVariants, invalidVariant(String), variantConflict(String, owner: String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "Введите слово или название"
            case .invalid: return "Запись должна содержать буквы и не должна содержать запятые, точки с запятой или переносы строк"
            case .duplicate: return "Такая запись уже есть в словаре"
            case .stale: return "Словарь изменился. Выберите запись заново."
            case .emptyVariants: return "Введите хотя бы один вариант, отличный от правильного написания"
            case .invalidVariant(let form): return "Вариант «\(form)» должен содержать буквы"
            case .variantConflict(let form, let owner): return "«\(form)» уже относится к записи «\(owner)»"
            }
        }
    }

    public static func entries(in vocabulary: String) -> [Entry] {
        let expression = try! NSRegularExpression(pattern: "[^,;\\r\\n]+")
        return expression.matches(in: vocabulary, range: NSRange(vocabulary.startIndex..., in: vocabulary)).compactMap { match in
            guard let rawRange = Range(match.range, in: vocabulary) else { return nil }
            let raw = vocabulary[rawRange]
            guard let first = raw.firstIndex(where: { !$0.isWhitespace }),
                  let last = raw.lastIndex(where: { !$0.isWhitespace }) else { return nil }
            let range = first..<vocabulary.index(after: last)
            return Entry(text: String(vocabulary[range]), source: vocabulary, range: NSRange(range, in: vocabulary))
        }
    }

    /// Validates one explicit entry without changing its spelling or abbreviation form.
    public static func validatedText(_ input: String) throws -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure.empty }
        guard text.rangeOfCharacter(from: separators) == nil,
              text.rangeOfCharacter(from: .newlines) == nil,
              TranscriptTerms.adding(text, to: "") != "" else { throw Failure.invalid }
        return text
    }

    public static func replacing(_ entry: Entry, with input: String, in vocabulary: String) throws -> String {
        try requireSnapshot(entry.source, in: vocabulary)
        let replacement = try validatedText(input)
        if replacement.utf8.elementsEqual(entry.text.utf8) { return vocabulary }
        let remaining = NSMutableString(string: vocabulary)
        remaining.replaceCharacters(in: entry.range, with: "")
        let withoutSelected = remaining as String
        // Explicit edits retain their full spelling; shared family rules may
        // normalize an inflected form before testing membership.
        let literalKey = literalKey(replacement)
        guard !entries(in: withoutSelected).contains(where: { self.literalKey($0.text) == literalKey }) else {
            throw Failure.duplicate
        }
        guard TranscriptTerms.adding(replacement, to: withoutSelected) != withoutSelected else { throw Failure.duplicate }
        let result = NSMutableString(string: vocabulary)
        result.replaceCharacters(in: entry.range, with: replacement)
        return result as String
    }

    public static func replacing(_ entry: Entry, with input: String, variantInput: String, in vocabulary: String,
                                 variants: [String: [String]]) throws -> (vocabulary: String, variants: [String: [String]]) {
        let canonical = try validatedText(input)
        let updatedVocabulary = try replacing(entry, with: canonical, in: vocabulary)
        var updatedVariants = variants
        updatedVariants.removeValue(forKey: entry.text)
        return (updatedVocabulary, try updatingVariants(parseVariants(variantInput), for: canonical,
                                                         in: updatedVocabulary, variants: updatedVariants))
    }

    public static func removing(_ entry: Entry, from vocabulary: String,
                                variants: [String: [String]] = [:]) throws -> Removal {
        try requireSnapshot(entry.source, in: vocabulary)
        let result = NSMutableString(string: vocabulary)
        result.replaceCharacters(in: entry.range, with: "")
        let updatedVocabulary = result as String
        var updatedVariants = variants
        let removedVariants = entries(in: updatedVocabulary).contains(where: { $0.text == entry.text })
            ? [] : updatedVariants.removeValue(forKey: entry.text) ?? []
        return Removal(vocabulary: updatedVocabulary, variants: updatedVariants, range: entry.range,
                       removed: entry.text, removedVariants: removedVariants)
    }

    public static func canonicalSpelling(for term: String, in vocabulary: String) -> String {
        canonicalTerm(for: term, in: vocabulary) ?? term
    }

    private static func canonicalTerm(for input: String, in vocabulary: String) -> String? {
        let dictionary = entries(in: vocabulary)
        if let exact = dictionary.first(where: { $0.text == input }) { return exact.text }
        let exactKey = literalKey(input)
        if let equivalent = dictionary.first(where: { literalKey($0.text) == exactKey }) { return equivalent.text }
        let base = TranscriptTerms.dictionaryTerm(input)
        let baseKey = literalKey(base)
        return dictionary.first(where: { literalKey($0.text) == baseKey })?.text
            ?? AbbreviationFamilies(vocabulary).known(base)?.base
    }

    public static func variantOwner(of form: String, in variants: [String: [String]]) -> String? {
        let key = literalKey(form)
        return variants.keys.sorted().first { owner in variants[owner]?.contains { literalKey($0) == key } == true }
    }

    public static func addingVariants(_ input: String, for term: String, to vocabulary: String,
                                      variants: [String: [String]]) throws -> (vocabulary: String, variants: [String: [String]]) {
        let requested = try validatedText(term)
        let savedTerm = canonicalTerm(for: requested, in: vocabulary)
        let updatedVocabulary = savedTerm == nil ? TranscriptTerms.adding(requested, to: vocabulary) : vocabulary
        guard let canonical = savedTerm ?? canonicalTerm(for: requested, in: updatedVocabulary) else { throw Failure.invalid }
        let additions = try parseVariants(input)
        guard additions.contains(where: { literalKey($0) != literalKey(canonical) }) else { throw Failure.emptyVariants }
        let forms = variants[canonical, default: []] + additions
        return (updatedVocabulary, try updatingVariants(forms, for: canonical, in: updatedVocabulary, variants: variants))
    }

    private static func parseVariants(_ input: String) throws -> [String] {
        try input.components(separatedBy: separators).compactMap { part in
            let form = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !form.isEmpty else { return nil }
            guard (try? validatedText(form)) != nil else { throw Failure.invalidVariant(form) }
            return form
        }
    }

    private static func updatingVariants(_ forms: [String], for canonical: String, in vocabulary: String,
                                         variants: [String: [String]]) throws -> [String: [String]] {
        var updated = variants
        updated.removeValue(forKey: canonical)
        if let owner = variantOwner(of: canonical, in: updated) {
            throw Failure.variantConflict(canonical, owner: owner)
        }
        let canonicalKeys = Dictionary(entries(in: vocabulary).map { (literalKey($0.text), $0.text) },
                                       uniquingKeysWith: { first, _ in first })
        var seen = Set([literalKey(canonical)])
        var unique: [String] = []
        for form in forms {
            let key = literalKey(form)
            guard seen.insert(key).inserted else { continue }
            if let owner = canonicalKeys[key] ?? variantOwner(of: form, in: updated) {
                throw Failure.variantConflict(form, owner: owner)
            }
            unique.append(form)
        }
        if !unique.isEmpty { updated[canonical] = unique }
        return updated
    }

    public static func preview(_ input: String, vocabulary: String) -> Batch {
        var current = vocabulary
        var additions: [String] = []
        var duplicates: [String] = []
        var invalid: [String] = []
        var emptyCount = 0
        for part in input.components(separatedBy: separators) {
            let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { emptyCount += 1; continue }
            guard (try? validatedText(text)) != nil else { invalid.append(text); continue }
            let updated = TranscriptTerms.adding(text, to: current)
            if updated == current {
                duplicates.append(text)
            } else {
                // Read the spelling produced by the shared term rules, including
                // any future family-aware normalization, instead of duplicating it.
                if let added = entries(in: updated).last { additions.append(added.text) }
                current = updated
            }
        }
        return Batch(additions: additions, duplicates: duplicates, invalid: invalid, emptyCount: emptyCount, vocabulary: current)
    }

    static func literalKey(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func requireSnapshot(_ snapshot: String, in current: String) throws {
        guard current.utf8.starts(with: snapshot.utf8) else { throw Failure.stale }
        guard current.utf8.count != snapshot.utf8.count else { return }
        let suffix = String(decoding: current.utf8.dropFirst(snapshot.utf8.count), as: UTF8.self)
        guard snapshot.isEmpty || endsWithSeparator(snapshot) || startsWithSeparator(suffix) else { throw Failure.stale }
    }

    private static func startsWithSeparator(_ text: String) -> Bool {
        text.unicodeScalars.first.map(separators.contains) ?? false
    }

    private static func endsWithSeparator(_ text: String) -> Bool {
        text.unicodeScalars.last.map(separators.contains) ?? false
    }
}
