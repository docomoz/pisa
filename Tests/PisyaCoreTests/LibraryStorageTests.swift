import XCTest
@testable import PisyaCore

final class LibraryStorageTests: XCTestCase {
    func testStorageCountsLocalFilesAndIgnoresSymlinks() throws {
        let library = try temporaryLibrary()
        let models = library.root.appendingPathComponent("Models/Qwen", isDirectory: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let model = models.appendingPathComponent("weights")
        try writeFile(to: model)
        let audio = try library.audioURL("meeting.caf")
        try writeFile(to: audio)
        try FileManager.default.createSymbolicLink(at: library.audioURL("linked.caf"), withDestinationURL: model)
        let meeting = try saveMeeting(in: library, date: .distantPast, files: ["meeting.caf"])
        let json = library.meetingsDirectory.appendingPathComponent(meeting.id.uuidString + ".json")

        let storage = try library.storageUsage()
        XCTAssertEqual(storage.audioFiles, ["meeting.caf": try allocatedBytes(audio)])
        XCTAssertEqual(storage.audioBytes, try allocatedBytes(audio))
        XCTAssertEqual(storage.meetingBytes, try allocatedBytes(json))
        XCTAssertEqual(storage.otherBytes, try allocatedBytes(model))
    }

    func testCleanupOnlySelectsOlderFinishedMeetingsWithTextAndUnsharedAudio() throws {
        let library = try temporaryLibrary()
        let cutoff = Date(timeIntervalSince1970: 10_000)
        let old = cutoff.addingTimeInterval(-1)
        let ready = try saveMeeting(in: library, date: old, files: ["old.caf", "clean.caf", "shared.caf"])
        let new = try saveMeeting(in: library, date: cutoff, files: ["recent.caf", "shared.caf"])
        let pending = try saveMeeting(in: library, date: old, files: ["pending.caf"], status: .processing)
        let empty = try saveMeeting(in: library, date: old, files: ["empty.caf"], text: "")
        let queued = try saveMeeting(in: library, date: old, files: ["queued.caf"])
        for file in Set([ready, new, pending, empty, queued].flatMap(\.audioFiles)) {
            try writeFile(to: library.audioURL(file))
        }

        let usage = try library.storageUsage()
        let plan = usage.cleanupPlan(olderThan: cutoff, meetings: [ready, new, pending, empty, queued], excluding: [queued.id])
        XCTAssertEqual(plan.filesByMeeting, [ready.id: ["old.caf", "clean.caf"]])
        XCTAssertEqual(plan.bytes, try allocatedBytes(library.audioURL("old.caf")) + allocatedBytes(library.audioURL("clean.caf")))
    }

    func testRemovalKeepsTranscriptAndCanReconcileMissingFilesOnRetry() throws {
        let library = try temporaryLibrary()
        let meeting = try saveMeeting(in: library, date: .distantPast, files: ["gone.caf", "keep.caf", "shared.caf", "delete.caf", "directory.caf"])
        let removable = try library.audioURL("delete.caf")
        let retained = try library.audioURL("keep.caf")
        try writeFile(to: removable)
        try writeFile(to: retained)
        let shared = try library.audioURL("shared.caf")
        try writeFile(to: shared)
        let directory = try library.audioURL("directory.caf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let expectedBytes = try allocatedBytes(removable)

        let result = try library.removeAudio(from: meeting, names: ["gone.caf", "shared.caf", "delete.caf", "directory.caf"],
                                             keepingFiles: ["shared.caf"])
        XCTAssertEqual(result.bytes, expectedBytes)
        XCTAssertEqual(result.failedFiles, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        var expected = meeting
        expected.audioFiles = ["keep.caf", "directory.caf"]
        expected.audioOffsets = ["keep.caf": 3, "directory.caf": 3]
        XCTAssertEqual(try library.read(meeting.id), expected)
        XCTAssertEqual(result.meeting, expected)

        XCTAssertThrowsError(try library.removeAudio(from: meeting, names: ["keep.caf"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    private func temporaryLibrary() throws -> MeetingLibrary {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return try MeetingLibrary(root: root)
    }

    private func saveMeeting(in library: MeetingLibrary, date: Date, files: [String],
                             status: MeetingStatus = .ready, text: String = "Текст") throws -> Meeting {
        var meeting = Meeting(title: "Встреча", source: "Test")
        meeting.date = date
        meeting.status = status
        meeting.audioFiles = files
        meeting.audioOffsets = Dictionary(uniqueKeysWithValues: files.map { ($0, 3) })
        meeting.notes = "Заметки"
        meeting.folderID = UUID()
        var segment = TranscriptSegment(start: 3, end: 4, speaker: "Я", text: text)
        segment.audioFile = files.first
        meeting.segments = [segment]
        try library.save(meeting)
        return meeting
    }

    private func writeFile(to url: URL) throws {
        try Data(repeating: 1, count: 8_192).write(to: url)
    }

    private func allocatedBytes(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }
}
