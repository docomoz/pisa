import Foundation

func voiceNameForSelection(currentID: UUID?, currentName: String, segment: TranscriptSegment) -> String {
    currentID == segment.id ? currentName : segment.speaker
}

func voiceNameSuggestions(query: String, meetingNames: [String], savedNames: [String]) -> [String] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return [] }
    var seen = Set<String>()
    return (savedNames + meetingNames).compactMap { rawName in
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, seen.insert(name.lowercased()).inserted,
              name != query,
              name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
        return name
    }
}
