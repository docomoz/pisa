import Foundation

/// A second acoustic hypothesis is a hint for a new audio decode, never a text
/// replacement. Keep English, short replies and known vocabulary on their path.
enum RussianRecognition {
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    static func shouldRecheck(language: String?, duration: Double, original: String, alternative: String) -> Bool {
        guard language?.lowercased() == "russian", duration >= 2,
              MeetingSpeechText.accepts(alternative) else { return false }
        let first = words(original), second = words(alternative)
        return !first.isEmpty && first != second && similarLength(first, second)
    }

    static func context(vocabulary: String, hypothesis: String) -> String {
        [vocabulary, hypothesis].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func accepts(candidate: String, original: String, vocabulary: String) -> Bool {
        guard MeetingSpeechText.accepts(candidate) else { return false }
        let first = words(original), revised = words(candidate)
        guard similarLength(first, revised) else { return false }
        // An acoustic hint must not undo the user's explicit spellings that the
        // first audio decode already recognized. Match phrases, not substrings.
        return vocabulary.components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map(words).filter { !$0.isEmpty }.allSatisfy { phrase in
                !contains(first, phrase: phrase) || contains(revised, phrase: phrase)
            }
    }

    private static func similarLength(_ first: [String], _ second: [String]) -> Bool {
        !first.isEmpty && !second.isEmpty &&
            Double(second.count) >= Double(first.count) * 0.75 &&
            Double(second.count) <= Double(first.count) * 1.4
    }

    private static func contains(_ text: [String], phrase: [String]) -> Bool {
        guard text.count >= phrase.count else { return false }
        return (0...(text.count - phrase.count)).contains { Array(text[$0..<($0 + phrase.count)]) == phrase }
    }
}
