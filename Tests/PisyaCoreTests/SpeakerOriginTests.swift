import XCTest
@testable import PisyaCore

final class SpeakerOriginTests: XCTestCase {
    func testRenamedMicrophoneSpeakerKeepsItsOriginAfterSaving() throws {
        for filename in ["meeting-mic.caf", "meeting-mic.clean.caf"] {
            var segment = TranscriptSegment(start: 0, end: 5, speaker: "Я", text: "Реплика")
            segment.audioFile = filename
            segment.speaker = "Я или не я"
            let saved = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(segment))
            XCTAssertTrue(saved.isMicrophoneSpeaker)
        }
    }

    func testTrackTakesPrecedenceOverDisplayName() {
        for filename in ["meeting-remote.caf", "imported.wav"] {
            var segment = TranscriptSegment(start: 0, end: 5, speaker: "Я", text: "Реплика")
            segment.audioFile = filename
            XCTAssertFalse(segment.isMicrophoneSpeaker)
        }
    }

    func testLegacySegmentsWithoutTrackUseOriginalLabel() {
        XCTAssertTrue(TranscriptSegment(start: 0, end: 5, speaker: "Я", text: "Реплика").isMicrophoneSpeaker)
        XCTAssertFalse(TranscriptSegment(start: 0, end: 5, speaker: "Анна", text: "Реплика").isMicrophoneSpeaker)
    }
}
