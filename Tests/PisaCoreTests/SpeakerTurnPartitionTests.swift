import XCTest
@testable import PisaCore

final class SpeakerTurnPartitionTests: XCTestCase {
    func testSustainedOverlapPreservesCleanMajorityAndEmitsConflictOnce() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<2_000, speaker: 1),
            .init(range: 800..<1_000, speaker: 2)
        ], sampleCount: 2_000, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<800, 800..<1_000, 1_000..<2_000])
        XCTAssertEqual(result.map(\.exclusions), [[], [800..<1_000], []])
        XCTAssertTrue(result.allSatisfy(\.partitioned))
    }

    func testBriefInterjectionDoesNotFragmentTheDominantTurn() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<800, speaker: 1),
            .init(range: 400..<450, speaker: 2)
        ], sampleCount: 800, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<800, 400..<450])
        XCTAssertFalse(result.contains(where: \.partitioned))
        XCTAssertEqual(result[0].exclusions, [400..<450])
    }

    func testIntersectingVoicesCoverTheirUnionWithoutDuplicatesOrHoles() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<800, speaker: 1),
            .init(range: 200..<600, speaker: 2),
            .init(range: 400..<1_000, speaker: 3)
        ], sampleCount: 1_000, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<200, 200..<800, 800..<1_000])
        XCTAssertEqual(result.map(\.exclusions), [[], [200..<800], []])
        XCTAssertEqual(result.reduce(0) { $0 + $1.range.count }, 1_000)
    }

    func testSeparateTurnsAndSameSpeakerOverlapAreNotCompetingVoices() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<500, speaker: 1),
            .init(range: 100..<400, speaker: 1),
            .init(range: 700..<1_000, speaker: 2)
        ], sampleCount: 1_000, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<500, 100..<400, 700..<1_000])
        XCTAssertTrue(result.allSatisfy { $0.exclusions.isEmpty && !$0.partitioned })
    }

    func testMultipleShortConflictsCountTheirUnionAgainstTheDominantVoice() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<1_000, speaker: 1),
            .init(range: 200..<300, speaker: 2),
            .init(range: 600..<700, speaker: 2)
        ], sampleCount: 1_000, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<200, 200..<300, 300..<600, 600..<700, 700..<1_000])
        XCTAssertTrue(result.allSatisfy(\.partitioned))
    }

    func testBriefOverlapAtTheEdgeKeepsTheDominantTurnContext() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<2_000, speaker: 1),
            .init(range: 0..<200, speaker: 2),
            .init(range: 1_900..<2_300, speaker: 3)
        ], sampleCount: 2_300, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<200, 200..<2_000, 2_000..<2_300])
        XCTAssertEqual(result.map(\.exclusions), [[0..<200], [1_900..<2_000], []])
        XCTAssertFalse(SpeakerEmbeddingInput(range: result[1].range, exclusions: result[1].exclusions)
            .hasSustainedOverlap(sampleCount: 2_300, sampleRate: 100))
    }

    func testAbsorbedOverlapsStillRespectTheCumulativeTolerance() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<1_200, speaker: 1),
            .init(range: 0..<200, speaker: 2),
            .init(range: 600..<700, speaker: 3),
            .init(range: 1_100..<1_200, speaker: 4)
        ], sampleCount: 1_200, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<200, 200..<1_100, 1_100..<1_200])
        XCTAssertEqual(result.map(\.exclusions), [[0..<200], [600..<700], [1_100..<1_200]])
    }

    func testShortCleanTurnWithEnoughVoiceEvidenceIsNotDiscarded() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<1_000, speaker: 1),
            .init(range: 0..<800, speaker: 2)
        ], sampleCount: 1_000, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<800, 800..<1_000])
        XCTAssertEqual(result.map(\.exclusions), [[0..<800], []])
    }

    func testVectorlessCleanScrapsRetainAudioInTheUnknownContext() {
        let result = SpeakerTurnPartition.partition([
            .init(range: 0..<1_000, speaker: 1),
            .init(range: 30..<970, speaker: 2)
        ], sampleCount: 1_000, sampleRate: 100)
        XCTAssertEqual(result.map(\.range), [0..<1_000])
        XCTAssertEqual(result.map(\.exclusions), [[0..<1_000]])
        XCTAssertEqual(result.reduce(0) { $0 + $1.range.count }, 1_000)
    }
}
