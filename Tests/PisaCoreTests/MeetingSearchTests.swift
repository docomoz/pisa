import XCTest
@testable import PisaCore

final class MeetingSearchTests: XCTestCase {
    func testAllWordsMatchesRussianCaseAndYoWithoutChangingTheText() throws {
        let original = "Утверждён зелёный\u{00A0}цвет."
        let meeting = makeMeeting([("Ира", original), ("Ира", "Поменяли цвет на зелёный"), ("Ира", "Зелёный"), ("Ира", "Зелёный цветок")])

        let hits = MeetingSearch.fragments(in: [meeting], query: "ЗЕЛЕНЫЙ цвет")

        XCTAssertEqual(hits.map(\.segmentIndex), [0, 1])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.meeting.segments[hit.segmentIndex].text, original)
    }

    func testExactPhraseRequiresAdjacentWordsInOrderWithinOneSegment() {
        let meeting = makeMeeting([
            ("Ира", "цвет зелёный"),
            ("Ира", "зелёный или другой цвет"),
            ("Ира", "зелёный"),
            ("Ира", "цвет"),
            ("Ира", "Выбрали «зелёный цвет»."),
        ])

        let hits = MeetingSearch.fragments(in: [meeting], query: "зеленый цвет", mode: .exactPhrase)

        XCTAssertEqual(hits.map(\.segmentIndex), [4])
        XCTAssertTrue(MeetingSearch.fragments(in: [meeting], query: "— …").isEmpty)
    }

    func testDateBoundsFolderAndMeetingIDFilterTheSameMeetings() {
        let lower = Date(timeIntervalSince1970: 100)
        let upper = Date(timeIntervalSince1970: 200)
        let folderID = UUID()
        var matching = makeMeeting([("Ира", "релиз")], date: lower)
        matching.folderID = folderID
        var tooEarly = makeMeeting([("Ира", "релиз")], date: lower.addingTimeInterval(-1))
        tooEarly.folderID = folderID
        var atUpper = makeMeeting([("Ира", "релиз")], date: upper)
        atUpper.folderID = folderID
        let outsideFolder = makeMeeting([("Ира", "релиз")], date: lower)
        let meetings = [tooEarly, outsideFolder, matching, atUpper]
        let filters = MeetingSearchFilters(dateFrom: lower, dateTo: upper, folderID: folderID)

        XCTAssertEqual(meetings.filter(filters.matches).map(\.id), [matching.id])
        XCTAssertEqual(MeetingSearch.fragments(in: meetings, query: "релиз", filters: filters).map(\.meeting.id), [matching.id])
        let wrongID = MeetingSearchFilters(folderID: folderID, meetingID: outsideFolder.id)
        XCTAssertTrue(MeetingSearch.fragments(in: meetings, query: "релиз", filters: wrongID).isEmpty)
    }

    func testSpeakerFilterAppliesToMatchAndKeepsNeighborsFromOtherSpeakers() throws {
        let meeting = makeMeeting([
            ("Ира", "Обсудим релиз"),
            ("Артём\u{00A0}Котов", "Релиз в среду"),
            ("Ира", "Записала"),
        ])
        let filters = MeetingSearchFilters(speaker: " АРТЕМ КОТОВ ")

        XCTAssertTrue(filters.matches(meeting))
        XCTAssertFalse(MeetingSearchFilters(speaker: "Артем").matches(meeting))
        let hits = MeetingSearch.fragments(in: [meeting], query: "релиз", filters: filters, contextCount: 1)
        XCTAssertEqual(hits.map(\.segmentIndex), [1])
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.contextBefore.map { hit.meeting.segments[$0].speaker }, ["Ира"])
        XCTAssertEqual(hit.contextAfter.map { hit.meeting.segments[$0].text }, ["Записала"])
    }

    func testContextStaysWithinMeetingBoundsAndCanBeDisabled() throws {
        let meeting = makeMeeting([("Ира", "релиз"), ("Ира", "планы"), ("Ира", "обсуждение")])

        let hit = try XCTUnwrap(MeetingSearch.fragments(in: [meeting], query: "релиз", contextCount: 3).first)
        XCTAssertEqual(Array(hit.contextBefore), [])
        XCTAssertEqual(Array(hit.contextAfter), [1, 2])

        let noContext = try XCTUnwrap(MeetingSearch.fragments(in: [meeting], query: "планы", contextCount: 0).first)
        XCTAssertTrue(noContext.contextBefore.isEmpty)
        XCTAssertTrue(noContext.contextAfter.isEmpty)
    }

    func testRankingIsStableAndExcludesDeletedMeetings() {
        let early = Date(timeIntervalSince1970: 100)
        let late = Date(timeIntervalSince1970: 200)
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var first = makeMeeting([("Ира", "срок релиза"), ("Ира", "срок релиза")], date: early)
        first.id = firstID
        var second = makeMeeting([("Ира", "срок релиза")], date: early)
        second.id = secondID
        let recentPhrase = makeMeeting([("Ира", "срок релиза")], date: late)
        let recentWords = makeMeeting([("Ира", "релиза еще нет, срок обсудим")], date: late)
        var trashed = makeMeeting([("Ира", "срок релиза")], date: late)
        trashed.deletedAt = late
        let meetings = [trashed, recentWords, second, recentPhrase, first]

        let hits = MeetingSearch.fragments(in: meetings, query: "срок релиза")

        XCTAssertFalse(MeetingSearchFilters().matches(trashed))
        XCTAssertEqual(hits.map(\.meeting.id), [recentPhrase.id, firstID, firstID, secondID, recentWords.id])
        XCTAssertEqual(hits.map(\.segmentIndex), [0, 0, 1, 0, 0])
    }

    private func makeMeeting(
        _ lines: [(speaker: String, text: String)],
        date: Date = Date(timeIntervalSince1970: 100)
    ) -> Meeting {
        var meeting = Meeting(title: "Созвон", source: "Тест")
        meeting.date = date
        meeting.status = .ready
        meeting.segments = lines.enumerated().map { index, line in
            TranscriptSegment(start: Double(index), end: Double(index + 1), speaker: line.speaker, text: line.text)
        }
        return meeting
    }
}
