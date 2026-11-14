import XCTest
@testable import PisaCore

final class SegmentAudioRangeTests: XCTestCase {
    func testRangeUsesTrackOffsetAndClampsToAvailableAudio() {
        let range = SegmentAudioRange(start: 12, end: 16, offset: 10, duration: 5)
        XCTAssertEqual(range?.start, 2)
        XCTAssertEqual(range?.end, 5)
        XCTAssertEqual(range?.duration, 3)
    }

    func testUnavailableOrInvalidRangesAreRejected() {
        XCTAssertNil(SegmentAudioRange(start: 1, end: 2, offset: 5, duration: 10))
        XCTAssertNil(SegmentAudioRange(start: 4, end: 3, offset: 0, duration: 10))
        XCTAssertNil(SegmentAudioRange(start: .nan, end: 3, offset: 0, duration: 10))
    }
}
