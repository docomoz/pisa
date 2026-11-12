import XCTest
@testable import PisyaCore

final class LiveTranscriptionScheduleTests: XCTestCase {
    func testAudioProgressTracksOnlyCommittedAudio() {
        var schedule = LiveTranscriptionSchedule(committed: 15)
        let window = schedule.next(available: 60, stopped: true)!
        XCTAssertEqual(LiveTranscriptionSchedule.audioProgress(committed: schedule.committed, duration: 60), 0.25)
        schedule.commit(window)
        XCTAssertEqual(LiveTranscriptionSchedule.audioProgress(committed: schedule.committed, duration: 60), 0.5)
    }

    func testAudioProgressRequiresValidFinalDuration() {
        XCTAssertNil(LiveTranscriptionSchedule.audioProgress(committed: 15, duration: nil))
        XCTAssertNil(LiveTranscriptionSchedule.audioProgress(committed: 0, duration: 0))
        XCTAssertNil(LiveTranscriptionSchedule.audioProgress(committed: 15, duration: .infinity))
        XCTAssertNil(LiveTranscriptionSchedule.audioProgress(committed: 15, duration: 14))
    }

    func testOnlyCommittedWindowsAdvanceCursorAndStopDrainsTail() {
        var schedule = LiveTranscriptionSchedule(batchDuration: 15)
        XCTAssertNil(schedule.next(available: 14, stopped: false))
        let first = schedule.next(available: 16, stopped: false)!
        XCTAssertEqual(first.start, 0)
        XCTAssertEqual(first.end, 15)
        XCTAssertNil(schedule.next(available: 60, stopped: false))
        schedule.fail(first)
        let retry = schedule.next(available: 60, stopped: false)!
        XCTAssertEqual(first.start, retry.start)
        XCTAssertEqual(first.end, retry.end)
        schedule.commit(retry)
        let second = schedule.next(available: 32, stopped: true)!
        XCTAssertEqual(second.start, 15)
        XCTAssertEqual(second.end, 30)
        schedule.commit(second)
        let tail = schedule.next(available: 32, stopped: true)!
        XCTAssertEqual(tail.start, 30)
        XCTAssertEqual(tail.end, 32)
        schedule.commit(tail)
        XCTAssertNil(schedule.next(available: 32, stopped: true))
    }
    func testPauseDoesNotConsumeAndStopDuringFlightCanDrain() {
        var schedule = LiveTranscriptionSchedule(batchDuration: 15)
        XCTAssertNil(schedule.next(available: 100, stopped: false, paused: true))
        let inFlight = schedule.next(available: 100, stopped: false)!
        XCTAssertNil(schedule.next(available: 100, stopped: true))
        schedule.commit(inFlight)
        let next = schedule.next(available: 100, stopped: true, paused: true)!
        XCTAssertEqual(next.start, 15)
        XCTAssertEqual(next.end, 30)
    }
    func testRestoredCursorAndStaleCompletionCannotSkipAudio() {
        var schedule = LiveTranscriptionSchedule(batchDuration: 15, committed: 30)
        let first = schedule.next(available: 47, stopped: false)!
        schedule.fail(first)
        let retry = schedule.next(available: 47, stopped: false)!
        schedule.commit(first) // The old attempt cannot complete the retry.
        XCTAssertEqual(schedule.committed, 30)
        schedule.commit(retry)
        let tail = schedule.next(available: 47, stopped: true)!
        schedule.commit(first) // A late completion must not commit the newer tail.
        XCTAssertEqual(schedule.committed, 45)
        schedule.commit(tail)
        XCTAssertEqual(schedule.committed, 47)
        XCTAssertNil(schedule.next(available: .nan, stopped: true))
    }
    func testLookaheadKeepsCrossingUtterancesForNextWindow() {
        let segments = [
            TranscriptSegment(start: 10, end: 14, speaker: "Я", text: "done"),
            TranscriptSegment(start: 14, end: 16, speaker: "Я", text: "crossing"),
            TranscriptSegment(start: 13, end: 14.5, speaker: "Другой", text: "overlapping")
        ]
        let split = LiveTranscriptionSchedule.safeBoundary(start: 0, proposed: 15, segments: segments)
        XCTAssertEqual(split, 10)
        XCTAssertEqual(segments.filter { $0.end <= split }.count, 0)
        var schedule = LiveTranscriptionSchedule(batchDuration: 15)
        let first = schedule.next(available: 17, stopped: false)!
        schedule.commit(first, through: split)
        XCTAssertEqual(schedule.committed, 10)
        XCTAssertEqual(schedule.next(available: 17, stopped: true)?.start, 10)
    }
    func testCrossingRegionBeginningBeforeWindowDoesNotLoop() {
        let segment = TranscriptSegment(start: 0.9999, end: 18, speaker: "Я", text: "continuing")
        XCTAssertEqual(LiveTranscriptionSchedule.safeBoundary(start: 1, proposed: 16, segments: [segment]), 1)
    }
    func testCrossingUtteranceNearResumedBoundaryRequiresFallback() {
        let checkpoint = 2963.0
        var schedule = LiveTranscriptionSchedule(committed: checkpoint)
        let window = schedule.next(available: 3475, stopped: true)!
        let segments = [
            TranscriptSegment(start: checkpoint + 0.031, end: window.end + 1, speaker: "Я", text: "continuing"),
            TranscriptSegment(start: checkpoint + 3, end: checkpoint + 5, speaker: "Другой", text: "overlapping")
        ]
        XCTAssertEqual(LiveTranscriptionSchedule.safeBoundary(start: window.start, proposed: window.end, segments: segments),
                       checkpoint)
    }
    func testShortFinalWindowCanCommitItsFullLength() {
        let segment = TranscriptSegment(start: 30.2, end: 30.5, speaker: "Я", text: "done")
        XCTAssertEqual(LiveTranscriptionSchedule.safeBoundary(start: 30, proposed: 30.5, segments: [segment]), 30.5)
    }
    func testAcousticCutRequiresOneEarlyTurnClearlyCrossingTheBoundary() {
        var schedule = LiveTranscriptionSchedule(committed: 100)
        let window = schedule.next(available: 130, stopped: true)!
        XCTAssertTrue(window.speechBlocksCut(100.03..<116.5))
        XCTAssertFalse(window.speechBlocksCut(102.0..<116.5))
        XCTAssertFalse(window.speechBlocksCut(100.03..<115.1))
        XCTAssertFalse(window.speechBlocksCut(100.03..<114.7))
        XCTAssertFalse(window.speechBlocksCut(113..<117))
    }
    func testShortenedPassMustConfirmSpeechThroughCut() {
        var schedule = LiveTranscriptionSchedule(committed: 100)
        let window = schedule.next(available: 130, stopped: true)!
        let early = TranscriptSegment(start: 100.03, end: 114.8, speaker: "Я", text: "длинная реплика")
        let endsBeforeCut = TranscriptSegment(start: 100.03, end: 114, speaker: "Я", text: "пауза перед разрезом")
        XCTAssertTrue(window.confirmedSpeechThroughCut(early))
        XCTAssertFalse(window.confirmedSpeechThroughCut(endsBeforeCut))
    }
    func testResumeAndExplicitReprocessingChooseDifferentStartingPoints() {
        XCTAssertEqual(LiveTranscriptionSchedule.processingMode(committed: 30, reprocess: false), .resume(30))
        XCTAssertEqual(LiveTranscriptionSchedule.processingMode(committed: 30, reprocess: true), .fromStart)
        XCTAssertEqual(LiveTranscriptionSchedule.processingMode(committed: nil, reprocess: false), .fromStart)
    }
    func testSavedDraftRestoresCursorSegmentsAndLateTrackOffsetsTogether() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var meeting = Meeting(title: "Draft", source: "Системный звук")
        meeting.audioFiles = ["test-mic.caf", "test-remote.caf"]
        meeting.audioOffsets = ["test-mic.caf": 2.5, "test-remote.caf": 0]
        meeting.segments = [TranscriptSegment(start: 3, end: 4, speaker: "Я", text: "слова")]
        meeting.liveCommittedUntil = 15
        try library.save(meeting)
        let restored = try library.read(meeting.id)
        XCTAssertEqual(restored.liveCommittedUntil, 15)
        XCTAssertEqual(restored.audioOffsets, meeting.audioOffsets)
        XCTAssertEqual(restored.segments, meeting.segments)
        guard case .resume(let cursor) = LiveTranscriptionSchedule.processingMode(committed: restored.liveCommittedUntil, reprocess: false) else { return XCTFail("Expected resume") }
        var resumed = LiveTranscriptionSchedule(committed: cursor)
        XCTAssertEqual(resumed.next(available: 33, stopped: true)?.start, 15)
        XCTAssertEqual(LiveTranscriptionSchedule.processingMode(committed: restored.liveCommittedUntil, reprocess: true), .fromStart)
    }
    func testLongTurnRetriesWithMoreAudioAndCommitsDuringCall() {
        var schedule = LiveTranscriptionSchedule(batchDuration: 15)
        let initial = schedule.next(available: 15, stopped: false)!
        XCTAssertEqual(LiveTranscriptionSchedule.safeBoundary(start: 0, proposed: 15, segments: [TranscriptSegment(start: 0, end: 17, speaker: "Я", text: "длинная реплика")]), 0)
        XCTAssertTrue(schedule.deferBoundary(initial))
        XCTAssertNil(schedule.next(available: 29, stopped: false))
        let grown = schedule.next(available: 30, stopped: false)!
        XCTAssertNil(schedule.next(available: 60, stopped: false)) // One worker only.
        let end = LiveTranscriptionSchedule.safeBoundary(start: 0, proposed: grown.end, segments: [TranscriptSegment(start: 0, end: 25, speaker: "Я", text: "длинная реплика")])
        XCTAssertEqual(end, 30)
        schedule.commit(grown, through: end)
        XCTAssertEqual(schedule.next(available: 45, stopped: false)?.start, 30)
    }
    func testBoundaryGrowthStopsAtOneMinute() {
        var schedule = LiveTranscriptionSchedule(batchDuration: 15)
        for end in [15.0, 30, 45] {
            let window = schedule.next(available: end, stopped: false)!
            XCTAssertEqual(window.end, end)
            XCTAssertTrue(schedule.deferBoundary(window))
        }
        let last = schedule.next(available: 60, stopped: false)!
        XCTAssertEqual(last.end, 60)
        XCTAssertFalse(schedule.deferBoundary(last))
        XCTAssertEqual(schedule.committed, 0)
    }
}
