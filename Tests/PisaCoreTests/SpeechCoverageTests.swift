import XCTest
@testable import PisaCore

final class SpeechCoverageTests: XCTestCase {
    func testShortLanguageRereadUsesOnlyTheDiarizedFramesInsideThePaddedInput() {
        XCTAssertEqual(SpeechCoverage.unpaddedShortTurn(start: 0.125, duration: 0.75, sampleCount: 16_000), 2000..<14_000)
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: 0, duration: 1, sampleCount: 16_000))
        XCTAssertEqual(SpeechCoverage.unpaddedShortTurn(start: 0, duration: 1, sampleCount: 16_000,
                                                       includeAlreadyIsolated: true), 0..<16_000)
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: -0.1, duration: 1, sampleCount: 16_000,
                                                      includeAlreadyIsolated: true))
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: -0.1, duration: 0.75, sampleCount: 16_000))
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: 0.5, duration: 0.75, sampleCount: 16_000))
        XCTAssertNil(SpeechCoverage.unpaddedShortTurn(start: 0, duration: 3, sampleCount: 64_000))
    }

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

    func testShortIsolatedSpeechSurvivesPaddingThatWouldDropItsRemainder() {
        let turn = 12_697..<18_420
        let diarized = [0..<10_000, 22_420..<40_000]
        let padded = [0..<14_000, 20_420..<40_000]
        XCTAssertEqual(SpeechCoverage.uncovered(speech: [turn], covered: padded,
                                                sampleCount: 40_000, minimumPartialLength: 4_800), [])
        let protected = SpeechCoverage.shortSpeechHiddenByPadding(speech: [turn], diarized: diarized,
            padded: padded, sampleCount: 40_000, maximumLength: 8_000, minimumPartialLength: 4_800) {
                $0 == turn
            }
        XCTAssertEqual(protected, [turn])
        XCTAssertEqual(SpeechCoverage.trimPadding(padded[0], around: diarized[0], avoiding: protected), 0..<12_697)
        XCTAssertEqual(SpeechCoverage.trimPadding(17_500..<40_000, around: diarized[1], avoiding: protected), 18_420..<40_000)
    }

    func testOneSidedPaddingCanSuppressShortSpeechBeforeDiarizedContinuation() {
        let speech = [101_472..<119_328]
        let diarized = [0..<98_775, 111_195..<119_835]
        let padded = [0..<102_775, 107_195..<123_835]
        let shortTurn = 101_472..<107_195
        XCTAssertEqual(SpeechCoverage.uncovered(speech: speech, covered: padded,
                                                sampleCount: 960_000, minimumPartialLength: 4_800), [])
        var checked: [Range<Int>] = []
        let protected = SpeechCoverage.shortSpeechHiddenByPadding(speech: speech, diarized: diarized,
            padded: padded, sampleCount: 960_000, maximumLength: 8_000, minimumPartialLength: 4_800) {
                checked.append($0)
                return true
            }
        XCTAssertEqual(checked, [shortTurn])
        XCTAssertEqual(protected, [shortTurn])
        XCTAssertEqual(SpeechCoverage.trimPadding(padded[0], around: diarized[0], avoiding: protected), 0..<101_472)
        XCTAssertEqual(SpeechCoverage.trimPadding(padded[1], around: diarized[1], avoiding: protected), padded[1])
    }

    func testShortSpeechProtectionLeavesOrdinaryRecoveryAndDiarizedOverlapAlone() {
        let diarized = [0..<10_000, 30_000..<40_000]
        let padded = [0..<14_000, 26_000..<40_000]
        let weakCases = [
            9_500..<14_500,   // Overlaps diarization and the true gap is too short.
            11_000..<16_000,  // Isolated geometry passes, local VAD does not.
            11_000..<13_000,  // Entire excerpt already reaches neighboring recognition.
            13_000..<19_000,  // Ordinary coverage preserves the remainder.
            13_000..<22_000,  // Longer than the short-turn limit.
            17_000..<20_000,  // Ordinary coverage preserves the entire turn.
        ]
        for turn in weakCases {
            var checks: [Range<Int>] = []
            let selected = SpeechCoverage.shortSpeechHiddenByPadding(speech: [turn], diarized: diarized,
                padded: padded, sampleCount: 40_000, maximumLength: 8_000, minimumPartialLength: 4_800) {
                    checks.append($0)
                    return turn != 11_000..<16_000
                }
            XCTAssertEqual(selected, [], "\(turn)")
            XCTAssertEqual(checks, turn == 11_000..<16_000 ? [turn] : [], "\(turn)")
        }
        XCTAssertEqual(SpeechCoverage.trimPadding(padded[0], around: diarized[0], avoiding: []), padded[0])
    }

    func testTwoSidedPaddingNeedsAnUnambiguousShortSpeechWindow() {
        let padded = [0..<6_000, 8_500..<15_000]
        let speech = [3_000..<12_000]
        var checked: [Range<Int>] = []
        let ambiguous = SpeechCoverage.shortSpeechHiddenByPadding(speech: speech,
            diarized: [0..<3_000, 12_000..<15_000], padded: padded,
            sampleCount: 15_000, maximumLength: 8_000, minimumPartialLength: 4_800) {
                checked.append($0)
                return true
            }
        XCTAssertEqual(ambiguous, [])
        XCTAssertEqual(checked, [])

        let combined = SpeechCoverage.shortSpeechHiddenByPadding(speech: [3_200..<10_800],
            diarized: [0..<3_000, 11_000..<15_000], padded: padded,
            sampleCount: 15_000, maximumLength: 8_000, minimumPartialLength: 4_800) {
                checked.append($0)
                return true
            }
        XCTAssertEqual(combined, [3_200..<10_800])
        XCTAssertEqual(checked, combined)
    }

    func testShortSpeechProtectionDoesNotCutWordsAtDiarizationEdges() {
        let cases = [
            (speech: [608_352..<929_312], diarized: [859_635..<922_005], padded: [855_635..<926_005]),
            (speech: [20_576..<177_184], diarized: [495..<170_055], padded: [247..<174_055]),
            (speech: [887_904..<951_328], diarized: [893_115..<910_665], padded: [889_115..<910_665]),
        ]
        for sample in cases {
            let protected = SpeechCoverage.shortSpeechHiddenByPadding(speech: sample.speech, diarized: sample.diarized,
                padded: sample.padded, sampleCount: 960_000, maximumLength: 8_000, minimumPartialLength: 4_800) { turn in
                    XCTFail("Diarization edge should veto \(turn) before local VAD")
                    return true
                }
            XCTAssertEqual(protected, [])
        }
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
