import XCTest
@testable import PisyaCore

final class SpeechChunkingTests: XCTestCase {
    func testLongSpeechCutsInsidePauseAndKeepsEverySampleOnce() {
        let rate = 1000
        var samples = [Float](repeating: 0.3, count: 31 * rate)
        samples.replaceSubrange(21_000..<21_400, with: repeatElement(0, count: 400))
        let ranges = SpeechChunking.ranges(in: samples, range: 0..<samples.count, sampleRate: rate)
        XCTAssertEqual(ranges.count, 2)
        XCTAssertTrue((21_050...21_350).contains(ranges[0].upperBound))
        XCTAssertEqual(ranges[0].lowerBound, 0)
        XCTAssertEqual(ranges[0].upperBound, ranges[1].lowerBound)
        XCTAssertEqual(ranges[1].upperBound, 31_000)
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, samples.count)
    }

    func testShortTurnAndSpeakerBoundsArePreserved() {
        let samples = [Float](repeating: 0.1, count: 40_000)
        XCTAssertEqual(SpeechChunking.ranges(in: samples, range: 2_000..<2_300, sampleRate: 1000), [2_000..<2_300])
        let ranges = SpeechChunking.ranges(in: samples, range: 3_000..<34_000, sampleRate: 1000)
        XCTAssertEqual(ranges.first?.lowerBound, 3_000)
        XCTAssertEqual(ranges.last?.upperBound, 34_000)
        XCTAssertTrue(ranges.allSatisfy { $0.count <= 24_000 && !$0.isEmpty })
    }

    func testNearLimitKeepsTheEndOfThePhraseInContext() {
        let samples = [Float](repeating: 0.1, count: 24_100)
        let ranges = SpeechChunking.ranges(in: samples, range: 0..<samples.count, sampleRate: 1000)
        XCTAssertEqual(ranges, [0..<24_100])
    }

    func testLongUnbrokenSpeechHasBoundedContiguousWindows() {
        let samples = [Float](repeating: 0.2, count: 125_000)
        let ranges = SpeechChunking.ranges(in: samples, range: 0..<samples.count, sampleRate: 1000)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        XCTAssertTrue(ranges.allSatisfy { !$0.isEmpty && $0.count <= 24_000 })
        for pair in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
    }
}
