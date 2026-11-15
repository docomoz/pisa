import XCTest
@testable import PisaCore

final class SpeakerRecoveryTests: XCTestCase {
    func testIndependentPartsMustAgreeBeforeRecoveringAVoice() {
        XCTAssertNotNil(SpeakerRecovery.coherentEmbedding([[1, 0], [0.95, 0.1]]))
        XCTAssertNil(SpeakerRecovery.coherentEmbedding([[1, 0], [0, 1]]))
        XCTAssertNil(SpeakerRecovery.coherentEmbedding([[1, 0], nil]))
        XCTAssertNil(SpeakerRecovery.coherentEmbedding([[1, 0]]))
        XCTAssertNil(SpeakerRecovery.coherentEmbedding([[1, 0], [.nan, 0]]))
        XCTAssertNil(SpeakerRecovery.coherentEmbedding([[1, 0], [1, 0, 0]]))
    }

    func testSameVoiceGroupsAcrossWindowsButDifferentVoicesStaySeparate() {
        let evidence = [
            SpeakerRecovery.Evidence(range: 0..<60, vector: [1, 0]),
            .init(range: 60..<120, vector: [0.98, 0.1]),
            .init(range: 120..<180, vector: [0, 1]),
            .init(range: 180..<240, vector: [0.1, 0.98])
        ]
        let result = SpeakerRecovery.group(evidence, maximumSamples: 240)
        XCTAssertEqual(result.map(\.range), [0..<120, 120..<240])
        XCTAssertGreaterThan(VoiceMatcher.similarity(result[0].vector!, [1, 0]), 0.99)
        XCTAssertLessThan(VoiceMatcher.similarity(result[0].vector!, result[1].vector!), 0.3)
    }

    func testMixedBridgeCannotJoinTwoDistinctVoices() {
        let result = SpeakerRecovery.group([
            .init(range: 0..<60, vector: [1, 0]),
            .init(range: 60..<120, vector: [1, 1]),
            .init(range: 120..<180, vector: [0, 1])
        ], maximumSamples: 240)
        XCTAssertEqual(result.count, 2)
        XCTAssertNotEqual(result.first?.range, 0..<180)
    }

    func testUnknownAudioAndGapsCannotBeBorrowedByAnAdjacentVoice() {
        let result = SpeakerRecovery.group([
            .init(range: 0..<60, vector: [1, 0]),
            .init(range: 60..<120, vector: nil),
            .init(range: 120..<180, vector: [1, 0]),
            .init(range: 190..<240, vector: [1, 0])
        ], maximumSamples: 240)
        XCTAssertEqual(result.map(\.range), [0..<60, 60..<120, 120..<180, 190..<240])
        XCTAssertNil(result[1].vector)
    }

    func testPartitionsPreserveAllAudioAndLeaveEnoughForIndependentChecks() {
        for count in [10, 299, 300, 601, 1_200, 2_401] {
            let samples = [Float](repeating: 0.1, count: count + 20)
            let ranges = SpeakerRecovery.ranges(in: samples, range: 10..<(count + 10), sampleRate: 100)
            XCTAssertEqual(ranges.first?.lowerBound, 10)
            XCTAssertEqual(ranges.last?.upperBound, count + 10)
            XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, count)
            for index in ranges.indices.dropFirst() {
                XCTAssertEqual(ranges[index - 1].upperBound, ranges[index].lowerBound)
            }
            if count >= 300 { XCTAssertTrue(ranges.allSatisfy { $0.count >= 300 }) }
        }
    }

    func testAChangeInsideSixSecondsRecoversBothVoicesFromIndependentAudio() {
        let samples = [Float](repeating: 0.1, count: 600)
        let result = SpeakerRecovery.recover(in: samples, range: 0..<600, sampleRate: 100) { range in
            range.upperBound <= 300 ? [1, 0] : range.lowerBound >= 300 ? [0, 1] : [1, 1]
        }
        XCTAssertEqual(result.map(\.range), [0..<300, 300..<600])
        XCTAssertEqual(result[0].vector, [1, 0])
        XCTAssertEqual(result[1].vector, [0, 1])
    }

    func testShortRecoveryCannotInventOrBorrowEvidence() {
        var calls = 0
        let result = SpeakerRecovery.recover(in: [Float](repeating: 0.1, count: 299), range: 0..<299, sampleRate: 100) { _ in
            calls += 1
            return [1, 0]
        }
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.map(\.range), [0..<299])
        XCTAssertNil(result.first?.vector)
    }

    func testAveragedProbesCannotHideAContradictionBetweenRecoveredWindows() {
        let a: [Float] = [1, 0], b: [Float] = [0.7, 0.714], c: [Float] = [0, 1]
        let result = SpeakerRecovery.group([
            .init(range: 0..<60, vector: [1.7, 0.714], probes: [a, b]),
            .init(range: 60..<120, vector: [0.7, 1.714], probes: [b, c])
        ], maximumSamples: 240)
        XCTAssertEqual(result.count, 2)
    }

    func testRecognitionContextStaysInsideRecoveredGapWithoutChangingEvidence() {
        XCTAssertEqual(SpeakerRecovery.recognitionRange(for: 100..<400, in: 100..<900, padding: 12), 100..<412)
        XCTAssertEqual(SpeakerRecovery.recognitionRange(for: 400..<700, in: 100..<900, padding: 12), 388..<712)
        XCTAssertEqual(SpeakerRecovery.recognitionRange(for: 700..<900, in: 100..<900, padding: 12), 688..<900)
        XCTAssertEqual(SpeakerRecovery.recognitionRange(for: 100..<900, in: 100..<900, padding: 12), 100..<900)
    }

    func testGroupingKeepsRecognitionChunksBounded() {
        let evidence = (0..<12).map { SpeakerRecovery.Evidence(range: ($0 * 60)..<(($0 + 1) * 60), vector: [1, 0]) }
        let result = SpeakerRecovery.group(evidence, maximumSamples: 240)
        XCTAssertEqual(result.map(\.range), [0..<240, 240..<480, 480..<720])
    }
}
