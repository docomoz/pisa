import XCTest
@testable import PisaCore

final class InterruptedTranscriptionProgressTests: XCTestCase {
    func testSavedDraftProgressIncludesProcessedSilence() throws {
        var meeting = Meeting(title: "Черновик", source: "Запись")
        meeting.status = .failed
        meeting.duration = 150
        meeting.liveCommittedUntil = 30

        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(restored.interruptedTranscriptionProgress, .savedAudio(0.2))
    }

    func testBatchProgressSurvivesReloadWithoutSavedTranscript() throws {
        var meeting = Meeting(title: "Аудиофайл", source: "Аудиофайл")
        meeting.status = .failed
        meeting.interruptedBatchProgress = 0.36

        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(restored.interruptedTranscriptionProgress, .batch(0.36))
        XCTAssertNil(restored.liveCommittedUntil)
    }

    func testBatchProgressCannotDisplayCompletionBeforeTheResultIsSaved() {
        var meeting = Meeting(title: "Аудиофайл", source: "Аудиофайл")
        meeting.status = .failed
        meeting.interruptedBatchProgress = 1
        XCTAssertEqual(meeting.interruptedTranscriptionProgress, .batch(0.99))

        meeting.status = .ready
        XCTAssertNil(meeting.interruptedTranscriptionProgress)
    }

    func testOlderFailedMeetingWithoutCheckpointHasNoEstimate() throws {
        var meeting = Meeting(title: "Старая встреча", source: "Запись")
        meeting.status = .failed
        meeting.duration = 150
        meeting.segments = [TranscriptSegment(start: 0, end: 30, speaker: "Анна", text: "Старая реплика")]

        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertNil(restored.interruptedTranscriptionProgress)
    }
}
