import Foundation

enum RecognitionPromptEcho {
    /// Every prompted audio pass uses the same guard. A single unprompted
    /// decode recovers speech rather than deleting the contaminated segment.
    static func decode<Output>(context: String, vocabulary: String, text: (Output) -> String,
                               generate: (String) throws -> Output) rethrows -> Output {
        let result = try generate(context)
        guard isEcho(text(result), context: context, vocabulary: vocabulary) else { return result }
        return try generate("")
    }

    static func isEcho(_ text: String, context: String, vocabulary: String) -> Bool {
        guard !context.isEmpty else { return false }
        let decoded = RussianRecognition.words(text)
        let prompt = RussianRecognition.words(context)
        let glossary = RussianRecognition.words(vocabulary)
        guard !decoded.isEmpty, !glossary.isEmpty, prompt.starts(with: glossary) else { return false }
        if decoded == prompt { return true }

        let minimumTerms = 5
        let entireGlossary = decoded == glossary
        guard entireGlossary || decoded.count >= minimumTerms else { return false }
        let entries = vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(RussianRecognition.words).filter { !$0.isEmpty }
        // A decoder can copy the whole list and omit the appended speech hint.
        // One term in isolation can also be a valid short answer.
        if entireGlossary { return Set(entries).count > 1 }

        // Only the actual glossary can yield a partial match. The acoustic
        // hypothesis appended to it may itself be valid conversational speech.
        guard Set(entries).count >= minimumTerms,
              prompt.starts(with: entries.joined()) else { return false }

        // Speech can continue after the copied glossary. Inspect every possible
        // endpoint; the terms themselves must still form one uninterrupted run
        // in glossary order. A retry, rather than deletion, preserves real lists.
        for end in stride(from: decoded.count, through: minimumTerms, by: -1) {
            let prefix = decoded.prefix(end)
            for index in entries.indices.reversed() where index >= minimumTerms - 1 {
                let last = entries[index]
                for width in 1...last.count where prefix.suffix(width).elementsEqual(last.prefix(width)) {
                    var matched: Set<[String]> = width == last.count ? [last] : []
                    var remaining = prefix.dropLast(width)
                    for entry in entries[..<index].reversed() {
                        guard remaining.suffix(entry.count).elementsEqual(entry) else { continue }
                        matched.insert(entry)
                        if matched.count >= minimumTerms { return true }
                        remaining = remaining.dropLast(entry.count)
                    }
                }
            }
        }
        return false
    }
}
