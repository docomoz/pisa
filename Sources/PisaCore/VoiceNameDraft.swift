import Foundation

func voiceNameForSelection(currentSpeaker: String?, currentName: String, segment: TranscriptSegment) -> String {
    currentSpeaker == segment.speaker ? currentName : segment.speaker
}

func isAutomaticSpeakerName(_ name: String) -> Bool {
    let words = name.split(whereSeparator: \.isWhitespace)
    if words.count == 1,
       words[0].caseInsensitiveCompare(TranscriptSegment.unidentifiedSpeaker) == .orderedSame { return true }
    return words.count == 2 && words[0].caseInsensitiveCompare("Спикер") == .orderedSame &&
        words[1].allSatisfy { $0.isASCII && $0.isNumber }
}

struct WordPrefixQuery {
    private let prefixes: [Substring]

    init?(_ query: String) {
        prefixes = Self.words(in: query)
        guard !prefixes.isEmpty else { return nil }
    }

    func matches(_ text: String) -> Bool {
        let words = Self.words(in: text)
        return prefixes.allSatisfy { prefix in words.contains { $0.hasPrefix(prefix) } }
    }

    private static func words(in text: String) -> [Substring] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
    }
}

func voiceNameSuggestions(query: String, meetingNames: [String], savedNames: [String]) -> [String] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let wordQuery = WordPrefixQuery(query) else { return [] }
    var seen = Set<String>()
    return (savedNames + meetingNames).compactMap { rawName in
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != TranscriptSegment.unidentifiedSpeaker,
              seen.insert(name.lowercased()).inserted, name != query, wordQuery.matches(name) else { return nil }
        return name
    }
}
