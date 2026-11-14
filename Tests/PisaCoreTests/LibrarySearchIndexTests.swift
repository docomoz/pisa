import XCTest
@testable import PisaCore

final class LibrarySearchIndexTests: XCTestCase {
    func testSearchesAndUpdatesEveryIndexedField() async {
        var meeting = Meeting(title: "Планы команды", source: "Звонок")
        meeting.notes = "Проверить бюджет"
        meeting.segments = [.init(start: 0, end: 1, speaker: "Анна", text: "Обсудим релиз")]
        let index = LibrarySearchIndex()
        index.replace([meeting])
        for query in ["КОМАНД", "бюджет", "анна", "РЕЛИЗ", "звонок"] {
            let result = await search(index, query)
            XCTAssertEqual(result, [meeting.id])
        }
        meeting.title = "Новое название"
        meeting.segments[0].speaker = "Мария"
        index.upsert(meeting)
        let old = await search(index, "анна")
        let updated = await search(index, "мария")
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(updated, [meeting.id])
        index.replace([])
        let removed = await search(index, "мария")
        XCTAssertTrue(removed.isEmpty)
    }

    func testUnicodeMatchesKeepLocalizedSearchSemantics() async {
        let values = ["Добрый ДЕНЬ", "한글 한글", "a\u{200C}bc", "👩‍💻", "Кофе и ёлка"]
        let queries = ["ё", "ᅡᆫ", "\u{200C}bc", "👩", "елка", "КОФЕ"]
        let meetings = values.map { Meeting(title: $0, source: "") }
        let index = LibrarySearchIndex()
        index.replace(meetings)
        for query in queries {
            let expected = Set(meetings.filter { $0.searchableText.localizedCaseInsensitiveContains(query) }.map(\.id))
            let actual = await search(index, query)
            XCTAssertEqual(actual, expected, "Query: \(query)")
        }
    }

    func testNewQueryReturnsLatestMatches() async {
        let index = LibrarySearchIndex()
        let meeting = Meeting(title: "Новая встреча", source: "")
        index.replace([meeting])
        let latest = expectation(description: "latest result")
        index.search("устаревший запрос") { _ in }
        index.search("новая") { result in
            XCTAssertEqual(result, [meeting.id])
            latest.fulfill()
        }
        await fulfillment(of: [latest], timeout: 2)
    }

    private func search(_ index: LibrarySearchIndex, _ query: String) async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            index.search(query) { continuation.resume(returning: $0) }
        }
    }
}
