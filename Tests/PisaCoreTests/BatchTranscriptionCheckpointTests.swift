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
        let first = TranscriptSegment(start: 65, end: 68, speaker: "Собеседники", text: "Mm-hmm.")
        let original = BatchTranscriptionCheckpoint(inputs: inputs)
        original.rangesCompleted[input.lastPathComponent] = 2
        original.recognition.segments = [first]
        original.recognition.lexicalBackchannels[first.id] = "угу"
        original.recognition.uncertainShortLanguage = [first.id]
        original.progress = 0.85
        original.recordRevision(index: 0, segment: first, text: "Угу.", progress: 0.92)
        try original.save(to: library.batchTranscriptionURL(meeting.id))

        let reopened = try MeetingLibrary(root: root)
        let url = reopened.batchTranscriptionURL(meeting.id)
        let restored = try XCTUnwrap(BatchTranscriptionCheckpoint.load(from: url))
        XCTAssertEqual(restored.inputs, inputs)
        XCTAssertEqual(restored.rangesCompleted["recording.caf"], 2)
        XCTAssertEqual(restored.recognition.segments, [first])
        XCTAssertEqual(restored.recognition.lexicalBackchannels, [first.id: "угу"])
        XCTAssertEqual(restored.recognition.uncertainShortLanguage, [first.id])
        XCTAssertEqual(restored.revisionCount, 1)
        XCTAssertEqual(restored.revisions[first.id], "Угу.")
        XCTAssertEqual(restored.progress, 0.92)
        XCTAssertEqual(try reopened.read(meeting.id), meeting)
        XCTAssertEqual(try reopened.all(), [meeting])

        try Data([1, 2, 3, 4]).write(to: input)
        let changedInputs = try BatchTranscriptionCheckpoint.Inputs(files: [(input, 0)], model: root, vocabulary: "", variants: [:])
        XCTAssertNotEqual(restored.inputs, changedInputs)

        try reopened.discardBatchTranscription(meeting.id)
        XCTAssertNil(try BatchTranscriptionCheckpoint.load(from: url))
    }

    func testLegacyCheckpointWithoutLexicalBackchannelsCanBeResumed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let inputs = try BatchTranscriptionCheckpoint.Inputs(files: [], model: url, vocabulary: "", variants: [:])
        let segment = TranscriptSegment(start: 0, end: 1, speaker: "Анна", text: "Угу")
        let original = BatchTranscriptionCheckpoint(inputs: inputs)
        original.recognition.segments = [segment]
        original.recognition.backchannels[segment.id] = "угу"
        try original.save(to: url)

        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        var checkpoint = try XCTUnwrap(plist as? [String: Any])
        var recognition = try XCTUnwrap(checkpoint["recognition"] as? [String: Any])
        recognition.removeValue(forKey: "lexicalBackchannels")
        recognition.removeValue(forKey: "uncertainShortLanguage")
        checkpoint["recognition"] = recognition
        try PropertyListSerialization.data(fromPropertyList: checkpoint, format: .binary, options: 0).write(to: url)

        let restored = try XCTUnwrap(BatchTranscriptionCheckpoint.load(from: url))
        XCTAssertEqual(restored.recognition.segments, [segment])
        XCTAssertEqual(restored.recognition.backchannels, [segment.id: "угу"])
        XCTAssertEqual(restored.recognition.lexicalBackchannels, [:])
        XCTAssertEqual(restored.recognition.uncertainShortLanguage, [])
    }

    func testTrimmingUncommittedSegmentsRemovesTheirLexicalBackchannels() throws {
        let model = FileManager.default.temporaryDirectory
        let inputs = try BatchTranscriptionCheckpoint.Inputs(files: [], model: model, vocabulary: "", variants: [:])
        let kept = TranscriptSegment(start: 0, end: 1, speaker: "Анна", text: "Угу")
        let dropped = TranscriptSegment(start: 1, end: 2, speaker: "Борис", text: "Да")
        let checkpoint = BatchTranscriptionCheckpoint(inputs: inputs)
        checkpoint.recognition.segments = [kept, dropped]
        checkpoint.recognition.lexicalBackchannels = [kept.id: "угу", dropped.id: "да"]
        checkpoint.recognition.uncertainShortLanguage = [kept.id, dropped.id]

        checkpoint.trimUncommittedSegments(after: 1)

        XCTAssertEqual(checkpoint.recognition.segments, [kept])
        XCTAssertEqual(checkpoint.recognition.lexicalBackchannels, [kept.id: "угу"])
        XCTAssertEqual(checkpoint.recognition.uncertainShortLanguage, [kept.id])
    }
}
