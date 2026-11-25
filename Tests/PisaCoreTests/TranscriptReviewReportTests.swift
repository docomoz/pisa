import XCTest
@testable import PisaCore

final class TranscriptReviewReportTests: XCTestCase {
    private func library() throws -> MeetingLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try MeetingLibrary(root: root)
    }

    private func write(_ report: TranscriptReviewReport, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
    }

    func testMarksMatchOnlyOriginalRawTextAndSegmentInSelectedMeeting() throws {
        let library = try library()
        var meeting = Meeting(title: "Планы", source: "Пример")
        let segment = TranscriptSegment(start: 1, end: 2, speaker: "Я", text: "сверим смету")
        meeting.segments = [segment]
        let meetingURL = library.meetingsDirectory.appendingPathComponent(meeting.id.uuidString + ".json")
        try JSONEncoder().encode(meeting).write(to: meetingURL, options: .atomic)
        let before = try Data(contentsOf: meetingURL)
        let mark = TranscriptReviewReport.Mark(segmentID: segment.id, originalText: segment.text, reason: "Спорное слово",
                                                reading: "репетиция", evidence: "Сверено с записью")
        try write(.init(schemaVersion: 1, meetingID: meeting.id, marks: [mark]), at: library.transcriptReviewURL(meeting.id))
        let stored = try XCTUnwrap(library.transcriptReviewMarks(for: meeting.id)[segment.id])
        XCTAssertTrue(stored.matches(segment))
        XCTAssertEqual(stored.reading, "репетиция")
        var edited = segment
        edited.text = segment.displayText
        XCTAssertFalse(stored.matches(edited))
        var rerecognized = segment
        rerecognized.id = UUID()
        XCTAssertFalse(stored.matches(rerecognized))
        XCTAssertEqual(try Data(contentsOf: meetingURL), before)
        XCTAssertEqual(try library.all(), [meeting])
        XCTAssertFalse(MarkdownExporter.render(meeting).contains("репетиция"))
        XCTAssertTrue(MeetingSearch.fragments(in: try library.all(), query: "репетиция").isEmpty)
        meeting.deletedAt = Date()
        try JSONEncoder().encode(meeting).write(to: meetingURL, options: .atomic)
        XCTAssertFalse(library.transcriptReviewMarks(for: meeting.id).isEmpty)
        try library.purgeTrashed(meeting.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.transcriptReviewURL(meeting.id).path))
    }

    func testForeignInvalidAndConflictingReportsDoNotSupplyMarks() throws {
        let library = try library(), id = UUID(), url = library.transcriptReviewURL(id)
        let mark = TranscriptReviewReport.Mark(segmentID: UUID(), originalText: "Один", reason: "Проверить число")
        let other = TranscriptReviewReport.Mark(segmentID: UUID(), originalText: "Два", reason: "Сверить имя")
        let blank = TranscriptReviewReport.Mark(segmentID: UUID(), originalText: "Три", reason: "  ")
        XCTAssertTrue(library.transcriptReviewMarks(for: id).isEmpty)
        for (version, meetingID) in [(2, id), (1, UUID())] {
            try write(.init(schemaVersion: version, meetingID: meetingID, marks: [mark]), at: url)
            XCTAssertTrue(library.transcriptReviewMarks(for: id).isEmpty)
        }
        try write(.init(schemaVersion: 1, meetingID: id, marks: [mark, mark, other, blank]), at: url)
        XCTAssertEqual(Set(library.transcriptReviewMarks(for: id).keys), [other.segmentID])
        try Data("{}".utf8).write(to: url)
        XCTAssertTrue(library.transcriptReviewMarks(for: id).isEmpty)
    }
}
