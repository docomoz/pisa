import XCTest
@testable import PisaCore

final class SpeakerClusteringTests: XCTestCase {
    func testLongMixedTurnDoesNotMergeDistinctVoices() {
        let turns = [
            turn(start: 0, duration: 3, embedding: [1, 0]),
            turn(start: 4, duration: 10, embedding: [1, 1]),
            turn(start: 15, duration: 3, embedding: [0, 1]),
            turn(start: 19, duration: 2, embedding: [1, 0]),
            turn(start: 22, duration: 2, embedding: [0, 1])
        ]

        let assigned = SpeakerClustering.assign(turns, profiles: [])

        XCTAssertEqual(assigned[0].speaker, "Спикер 1")
        XCTAssertEqual(assigned[2].speaker, "Спикер 2")
        XCTAssertEqual(assigned[3].speaker, assigned[0].speaker)
        XCTAssertEqual(assigned[4].speaker, assigned[2].speaker)
    }

    func testFinalLabelsDoNotMoveAnAnchorOntoAnIncompatibleVoice() {
        let angles = [22.71, -37.58, 28.63, -36.35, 6.78, 68.08, 19.45, -40.01]
        let durations = [6.402, 5.753, 9.631, 4.656, 4.791, 7.356, 3.403, 6.957]
        let turns = zip(angles, durations).enumerated().map { index, pair in
            let radians = pair.0 * Double.pi / 180
            return turn(start: Double(index * 12), duration: pair.1,
                embedding: [Float(cos(radians)), Float(sin(radians))])
        }

        let assigned = SpeakerClustering.assign(turns, profiles: [])

        XCTAssertNotEqual(assigned[4].speaker, assigned[5].speaker)
    }

    func testShortVariableTurnDoesNotSplitCoherentLongVoice() {
        let angles = [-20.0, 20.0, 45.0]
        let durations = [10.0, 8.0, 3.0]
        let turns = angles.indices.map { index in
            let radians = angles[index] * .pi / 180
            return turn(start: Double(index * 12), duration: durations[index],
                embedding: [Float(cos(radians)), Float(sin(radians))])
        }

        let assigned = SpeakerClustering.assign(turns, profiles: [])

        XCTAssertNotEqual(assigned[0].speaker, TranscriptSegment.unidentifiedSpeaker)
        XCTAssertEqual(assigned[0].speaker, assigned[1].speaker)
        XCTAssertEqual(assigned[0].speaker, assigned[2].speaker)
    }

    func testLongDistinctVoicesKeepTheirStrongerContradictionGuard() {
        let angles = [30.0, 0.0, 60.0]
        let durations = [10.0, 8.0, 7.0]
        let turns = angles.indices.map { index in
            let radians = angles[index] * .pi / 180
            return turn(start: Double(index * 12), duration: durations[index],
                embedding: [Float(cos(radians)), Float(sin(radians))])
        }

        let assigned = SpeakerClustering.assign(turns, profiles: [])

        XCTAssertNotEqual(assigned[1].speaker, TranscriptSegment.unidentifiedSpeaker)
        XCTAssertNotEqual(assigned[2].speaker, TranscriptSegment.unidentifiedSpeaker)
        XCTAssertNotEqual(assigned[1].speaker, assigned[2].speaker)
    }

    private func turn(start: Double, duration: Double, embedding: [Float]) -> TranscriptSegment {
        var segment = TranscriptSegment(start: start, end: start + duration, speaker: "Собеседники", text: "Реплика")
        segment.embedding = embedding
        return segment
    }
}

final class SpeakerSampleQualityTests: XCTestCase {
    func testMissingSegmentationDoesNotInventCompetingVoices() {
        XCTAssertFalse(SpeakerSampleQuality.hasSustainedConflict([]))
    }
    func testBriefInterferenceDoesNotDisableTheDominantVoice() {
        XCTAssertFalse(SpeakerSampleQuality.hasSustainedConflict([
            (1, 0.03, 7.74), (2, 6.05, 6.80)
        ]))
    }
    func testSustainedOverlapAndSequentialVoicesAreRejected() {
        XCTAssertTrue(SpeakerSampleQuality.hasSustainedConflict([(1, 0.03, 7.91), (2, 0.03, 7.45)]))
        XCTAssertTrue(SpeakerSampleQuality.hasSustainedConflict([(1, 0, 4), (2, 4, 8)]))
        XCTAssertTrue(SpeakerSampleQuality.hasSustainedConflict([(1, 0, 1), (2, 1, 2)]))
    }
    func testRepeatedRegionsDoNotDoubleCountCompetingSpeech() {
        XCTAssertFalse(SpeakerSampleQuality.hasSustainedConflict([(1, 0, 8), (2, 2, 3), (2, 2.2, 2.8)]))
    }
}
