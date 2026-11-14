import Foundation
import XCTest
@testable import PisaCore

final class MeetingAudioSizeTests: XCTestCase {
    func testAudioSizeAddsDistinctTracksAndHandlesMissingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var meeting = Meeting(title: "Test", source: "Test")
        try Data(repeating: 1, count: 1_500).write(to: library.audioURL("mic.caf"))
        try Data(repeating: 2, count: 2_500).write(to: library.audioURL("remote.caf"))
        meeting.audioFiles = ["mic.caf", "remote.caf", "mic.caf"]
        XCTAssertEqual(library.audioSize(for: meeting), 4_000)
        meeting.audioFiles.append("missing.caf")
        XCTAssertNil(library.audioSize(for: meeting))
    }

    func testAudioSizeLabelRoundsAndUsesSuitableUnits() {
        XCTAssertEqual(meetingAudioSizeLabel(400_000), "0,4 МБ")
        XCTAssertEqual(meetingAudioSizeLabel(87_400_000), "87 МБ")
        XCTAssertEqual(meetingAudioSizeLabel(1_500_000_000), "1,5 ГБ")
    }
}
