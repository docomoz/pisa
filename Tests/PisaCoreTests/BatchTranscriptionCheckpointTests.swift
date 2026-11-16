import XCTest
@testable import PisaCore

final class BatchTranscriptionCheckpointTests: XCTestCase {
    func testAReopenedLibraryRecoversRecognitionAndContextWithoutReplacingTheMeeting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var meeting = Meeting(title: "Встреча", source: "Аудиофайл")
        meeting.status = .processing
        meeting.segments = [TranscriptSegment(start: 0, end: 6, speaker: "Анна", text: "Предыдущая расшифровка")]
        try library.save(meeting)

        let input = try library.audioURL("recording.caf")
        try Data([1, 2, 3]).write(to: input)
        let inputs = try BatchTranscriptionCheckpoint.Inputs(files: [(input, 0)], model: root, vocabulary: "", variants: [:])
        let first = TranscriptSegment(start: 65, end: 68, speaker: "Собеседники", text: "Первый проход")
        let original = BatchTranscriptionCheckpoint(inputs: inputs)
        original.rangesCompleted[input.lastPathComponent] = 2
        original.recognition.segments = [first]
        original.progress = 0.85
        original.recordRevision(index: 0, segment: first, text: "После уточнения", progress: 0.92)
        try original.save(to: library.batchTranscriptionURL(meeting.id))

        let reopened = try MeetingLibrary(root: root)
        let url = reopened.batchTranscriptionURL(meeting.id)
        let restored = try XCTUnwrap(BatchTranscriptionCheckpoint.load(from: url))
        XCTAssertEqual(restored.inputs, inputs)
        XCTAssertEqual(restored.rangesCompleted["recording.caf"], 2)
        XCTAssertEqual(restored.recognition.segments, [first])
        XCTAssertEqual(restored.revisionCount, 1)
        XCTAssertEqual(restored.revisions[first.id], "После уточнения")
        XCTAssertEqual(restored.progress, 0.92)
        XCTAssertEqual(try reopened.read(meeting.id), meeting)
        XCTAssertEqual(try reopened.all(), [meeting])

        try Data([1, 2, 3, 4]).write(to: input)
        let changedInputs = try BatchTranscriptionCheckpoint.Inputs(files: [(input, 0)], model: root, vocabulary: "", variants: [:])
        XCTAssertNotEqual(restored.inputs, changedInputs)

        try reopened.discardBatchTranscription(meeting.id)
        XCTAssertNil(try BatchTranscriptionCheckpoint.load(from: url))
    }
}
