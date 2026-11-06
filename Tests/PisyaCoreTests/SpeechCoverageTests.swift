import XCTest
@testable import PisyaCore

final class SpeechCoverageTests: XCTestCase {
    func testRecoversMiddleOfContinuousSpeechWithDiarizedEdges() {
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [0..<480_000], covered: [0..<80_000, 240_000..<480_000],
                                                sampleCount: 480_000, minimumPartialLength: 4_800), [80_000..<240_000])
    }

    func testOverlappingSpeakerRegionsOnlyCoverTheirUnion() {
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [0..<300], covered: [150..<200, 50..<120, 70..<100, 110..<150],
                                                sampleCount: 300, minimumPartialLength: 30), [0..<50, 200..<300])
    }

    func testPartialPaddingSliversAreDiscardedWhileAnIsolatedShortTurnSurvives() {
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [0..<120, 180..<190], covered: [10..<100],
                                                sampleCount: 200, minimumPartialLength: 30), [180..<190])
    }

    func testClipsAndMergesDetectedSpeechWithoutTranscribingDuplicateSamples() {
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [65..<115, -30..<20, 10..<70], covered: [-10..<5, 80..<120],
                                                sampleCount: 100, minimumPartialLength: 5), [5..<80])
    }

    func testFullyCoveredSpeechAndEmptyAudioProduceNoGaps() {
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [10..<20, 30..<35], covered: [0..<40],
                                                sampleCount: 40, minimumPartialLength: 5), [])
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [0..<30], covered: [], sampleCount: 0, minimumPartialLength: 5), [])
    }
    func testJoinNearbySortsAndMergesGapsWithinLimit() {
        XCTAssertEqual(SpeechCoverage.joinNearby([90..<110, 0..<20, 27..<50, 50..<65], maximumGap: 7, maximumLength: 70),
                       [0..<65, 90..<110])
    }

    func testJoinNearbyRespectsCombinedLengthAndPreservesLongRegions() {
        XCTAssertEqual(SpeechCoverage.joinNearby([0..<40, 45..<80, 85..<120, 130..<240, 245..<250], maximumGap: 10, maximumLength: 90),
                       [0..<80, 85..<120, 130..<240, 245..<250])
    }

    func testJoinNearbyHandlesOverlapAdjacencyAndEmptyRanges() {
        XCTAssertEqual(SpeechCoverage.joinNearby([50..<60, 10..<30, 20..<40, 40..<50, 5..<5, -5..<0], maximumGap: 0, maximumLength: 100),
                       [10..<60])
        XCTAssertEqual(SpeechCoverage.joinNearby([0..<10, 9..<30], maximumGap: 0, maximumLength: 20),
                       [0..<10, 9..<30])
    }

    func testShortTurnsStaySeparateExceptWhenPaddingOverlaps() {
        let gap = 12_800, short = 48_000, shortGap = 4_000, cap = 480_000
        let ack = [90_208..<100_384, 107_104..<128_032]
        let name = [68_704..<178_208, 183_392..<224_000]
        XCTAssertEqual(SpeechCoverage.joinNearby(ack, maximumGap: gap, maximumLength: cap, shortTurnLength: short, maximumShortTurnGap: shortGap), ack)
        XCTAssertEqual(SpeechCoverage.joinNearby(name, maximumGap: gap, maximumLength: cap, shortTurnLength: short, maximumShortTurnGap: shortGap), name)
        let longTurns = [56_416..<124_960, 135_776..<272_000]
        XCTAssertEqual(SpeechCoverage.joinNearby(longTurns, maximumGap: gap, maximumLength: cap, shortTurnLength: short, maximumShortTurnGap: shortGap), [56_416..<272_000])
        let closeShortTurn = [62_560..<137_248, 140_384..<168_992]
        XCTAssertEqual(SpeechCoverage.joinNearby(closeShortTurn, maximumGap: gap, maximumLength: cap, shortTurnLength: short, maximumShortTurnGap: shortGap), [62_560..<168_992])
    }

    func testShortTurnRuleUsesLastOriginalRangeAndKeepsLengthLimit() {
        let ranges = [0..<64_000, 65_600..<73_600, 80_000..<144_000]
        XCTAssertEqual(SpeechCoverage.joinNearby(ranges, maximumGap: 12_800, maximumLength: 200_000, shortTurnLength: 48_000, maximumShortTurnGap: 4_000),
                       [0..<73_600, 80_000..<144_000])
        let longTurns = [0..<64_000, 67_200..<131_200]
        XCTAssertEqual(SpeechCoverage.joinNearby(longTurns, maximumGap: 12_800, maximumLength: 100_000, shortTurnLength: 48_000, maximumShortTurnGap: 4_000), longTurns)
    }

    func testExpansionUsesOnlyHalfOfAvailableNeighborGaps() {
        XCTAssertEqual(SpeechCoverage.safeExpansion(region: 100..<200, base: 90..<210, previousEnd: 60,
            nextStart: 260, sampleCount: 400, maximumPadding: 50), 80..<230)
        XCTAssertNil(SpeechCoverage.safeExpansion(region: 100..<200, base: 100..<200, previousEnd: 110,
            nextStart: 190, sampleCount: 400, maximumPadding: 50))
        XCTAssertNil(SpeechCoverage.safeExpansion(region: 100..<200, base: 90..<210, previousEnd: 80,
            nextStart: 220, sampleCount: 400, maximumPadding: 50))
        XCTAssertEqual(SpeechCoverage.safeExpansion(region: 10..<90, base: 10..<90, previousEnd: 0,
            nextStart: 100, sampleCount: 100, maximumPadding: 50), 5..<95)
    }

    func testMicrophoneReadPaddingPreservesRegionAndClipsToFile() {
        // A 250 ms pad at 16 kHz; imaginary neighbors outside the file allow
        // the full available edge context, while clipping to actual samples.
        XCTAssertEqual(SpeechCoverage.safeExpansion(region: 2_000..<12_000, base: 2_000..<12_000,
            previousEnd: -6_000, nextStart: 20_000, sampleCount: 30_000, maximumPadding: 4_000), 0..<16_000)
        XCTAssertEqual(SpeechCoverage.safeExpansion(region: 18_000..<29_000, base: 18_000..<29_000,
            previousEnd: 10_000, nextStart: 37_000, sampleCount: 30_000, maximumPadding: 4_000), 14_000..<30_000)
        XCTAssertEqual(SpeechCoverage.safeExpansion(region: 10_000..<20_000, base: 10_000..<20_000,
            previousEnd: 8_000, nextStart: 23_000, sampleCount: 30_000, maximumPadding: 4_000), 9_000..<21_500)
    }

}
