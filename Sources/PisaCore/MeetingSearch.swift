import Foundation

public struct MeetingSearchFilters: Sendable {
    private let dateFrom: Date?
    private let dateTo: Date?
    private let speaker: String?
    private let folderID: UUID?
    private let meetingID: UUID?

    /// The lower date bound is inclusive and the upper date bound is exclusive.
    public init(
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        speaker: String? = nil,
        folderID: UUID? = nil,
        meetingID: UUID? = nil
    ) {
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.speaker = speaker.map(Self.normalizedSpeaker)
        self.folderID = folderID
        self.meetingID = meetingID
    }

    public func matches(_ meeting: Meeting) -> Bool {
        matchesMeeting(meeting) && (speaker == nil || meeting.segments.contains { matchesSpeaker($0.speaker) })
    }

    fileprivate func matchesMeeting(_ meeting: Meeting) -> Bool {
        if let dateFrom, meeting.date < dateFrom { return false }
        if let dateTo, meeting.date >= dateTo { return false }
        if let folderID, meeting.folderID != folderID { return false }
        if let meetingID, meeting.id != meetingID { return false }
        return meeting.deletedAt == nil
    }

    fileprivate func matchesSpeaker(_ name: String) -> Bool {
        guard let speaker else { return true }
        return Self.normalizedSpeaker(name) == speaker
    }

    private static func normalizedSpeaker(_ name: String) -> String {
        foldedSearchText(name).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum MeetingSearch {
    public enum Mode: String, Sendable {
        case allWords = "all_words"
        case exactPhrase = "exact_phrase"
    }

    public struct Hit: Sendable {
        public let meeting: Meeting
        public let segmentIndex: Int
        public let contextBefore: Range<Int>
        public let contextAfter: Range<Int>
    }

    /// Return matching segments with adjacent indexes in transcript order.
    public static func fragments(
        in meetings: [Meeting],
        query: String,
        mode: Mode = .allWords,
        filters: MeetingSearchFilters = .init(),
        contextCount: Int = 1
    ) -> [Hit] {
        let queryWords = words(in: query)
        guard !queryWords.isEmpty else { return [] }
        let requiredWords = Set(queryWords)
        let contextCount = min(max(contextCount, 0), 3)
        var matches: [(hit: Hit, phrase: Bool)] = []

        for meeting in meetings where filters.matchesMeeting(meeting) {
            for (index, segment) in meeting.segments.enumerated() where filters.matchesSpeaker(segment.speaker) {
                let segmentWords = words(in: segment.text)
                guard requiredWords.isSubset(of: Set(segmentWords)) else { continue }
                let phrase = queryWords.count == 1 || segmentWords.indices.contains {
                    segmentWords[$0...].starts(with: queryWords)
                }
                guard mode == .allWords || phrase else { continue }

                let before = max(0, index - contextCount)..<index
                let after = (index + 1)..<min(meeting.segments.count, index + 1 + contextCount)
                matches.append((Hit(meeting: meeting, segmentIndex: index, contextBefore: before, contextAfter: after), phrase))
            }
        }

        return matches.sorted { lhs, rhs in
            if lhs.phrase != rhs.phrase { return lhs.phrase }
            let left = lhs.hit
            let right = rhs.hit
            if left.meeting.date != right.meeting.date { return left.meeting.date > right.meeting.date }
            if left.meeting.id != right.meeting.id { return left.meeting.id.uuidString < right.meeting.id.uuidString }
            return left.segmentIndex < right.segmentIndex
        }.map(\.hit)
    }

    private static func words(in text: String) -> [Substring] {
        foldedSearchText(text).split { !$0.isLetter && !$0.isNumber }
    }
}

private func foldedSearchText(_ text: String) -> String {
    text.lowercased().precomposedStringWithCanonicalMapping.replacingOccurrences(of: "ё", with: "е")
}
