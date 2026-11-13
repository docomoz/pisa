import XCTest
@testable import PisaCore

final class TranscriptLinkTests: XCTestCase {
    func testRoundTripAndExactResolution() throws {
        var meeting = Meeting(title: "Встреча", source: "test")
        let segment = TranscriptSegment(start: 10, end: 15, speaker: "Я", text: "Привет")
        meeting.segments = [segment]
        let link = try XCTUnwrap(TranscriptLink(meetingID: meeting.id, segmentID: segment.id, time: 10.25))
        XCTAssertEqual(link.url.scheme, "pisa")
        let parsed = try XCTUnwrap(TranscriptLink(url: link.url))
        XCTAssertEqual(parsed, link)
        XCTAssertEqual(parsed.resolve(in: meeting)?.segment.id, segment.id)
        XCTAssertEqual(parsed.resolve(in: meeting)?.isApproximate, false)
    }
    func testFallbackAndDeletedMeeting() throws {
        var meeting = Meeting(title: "Встреча", source: "test")
        let first = TranscriptSegment(start: 0, end: 5, speaker: "Я", text: "Первый")
        let second = TranscriptSegment(start: 10, end: 15, speaker: "Я", text: "Второй")
        meeting.segments = [first, second]
        let link = try XCTUnwrap(TranscriptLink(meetingID: meeting.id, segmentID: UUID(), time: 12))
        XCTAssertEqual(link.resolve(in: meeting)?.segment.id, second.id)
        XCTAssertEqual(link.resolve(in: meeting)?.isApproximate, true)
        meeting.deletedAt = Date()
        XCTAssertNil(link.resolve(in: meeting))
    }
    func testFallbackPrefersSegmentStartingAtSharedBoundary() throws {
        var meeting = Meeting(title: "Встреча", source: "test")
        let earlier = TranscriptSegment(start: 19, end: 20, speaker: "Я", text: "Раньше")
        let target = TranscriptSegment(start: 20, end: 21, speaker: "Я", text: "Нужная")
        let invalid = TranscriptSegment(start: .nan, end: 21, speaker: "Я", text: "Некорректная")
        meeting.segments = [invalid, earlier, target]
        let link = try XCTUnwrap(TranscriptLink(meetingID: meeting.id, segmentID: UUID(), time: 20))
        XCTAssertEqual(link.resolve(in: meeting)?.segment.id, target.id)
        XCTAssertEqual(link.resolve(in: meeting)?.isApproximate, true)
    }
    func testRejectsMalformedURLs() throws {
        let meeting = UUID().uuidString, segment = UUID().uuidString
        for raw in ["pisya://meeting/\(meeting)?segment=\(segment)&time=1", "file://meeting/\(meeting)?segment=\(segment)&time=1", "pisa://other/\(meeting)?segment=\(segment)&time=1", "pisa://meeting/../\(meeting)?segment=\(segment)&time=1", "pisa://meeting/\(meeting)?segment=\(segment)&time=-1", "pisa://meeting/\(meeting)?segment=\(segment)&time=nan", "pisa://meeting/\(meeting)?segment=\(segment)&time=1&time=2", "pisa://meeting/\(meeting)?segment=\(segment)&time=1&path=/tmp", "pisa://user@meeting/\(meeting)?segment=\(segment)&time=1", "pisa://meeting/\(meeting)?segment=\(segment)&time=1#x"] {
            XCTAssertNil(TranscriptLink(url: try XCTUnwrap(URL(string: raw))), raw)
        }
        XCTAssertNil(TranscriptLink(meetingID: UUID(), segmentID: UUID(), time: .infinity))
    }
}
