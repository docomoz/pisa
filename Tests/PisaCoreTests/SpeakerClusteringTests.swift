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

    func testRepeatedRecognizedTurnsNameTheirCoherentWeakerTurn() {
        let turns = [
            turn(start: 0, duration: 5, embedding: [1, 0]),
            turn(start: 6, duration: 5, embedding: [0.98, 0.2]),
            turn(start: 12, duration: 3, embedding: [0.7, 0.714])
        ]
        let result = SpeakerClustering.assign(turns, profiles: [VoiceProfile(name: "Анна", samples: [[1, 0]])])
        XCTAssertEqual(result.map(\.speaker), ["Анна", "Анна", "Анна"])
    }

    func testOneRecognizedTurnCannotNameAnEntireCluster() {
        let turns = [turn(start: 0, duration: 5, embedding: [1, 0]),
                     turn(start: 6, duration: 3, embedding: [0.7, 0.714])]
        let result = SpeakerClustering.assign(turns, profiles: [VoiceProfile(name: "Анна", samples: [[1, 0]])])
        XCTAssertEqual(result[0].speaker, "Анна")
        XCTAssertNotEqual(result[1].speaker, "Анна")
    }

    func testOverlappingOrDuplicatedEvidenceCannotPropagateAName() {
        for second in [turn(start: 1, duration: 5, embedding: [0.98, 0.2]),
                       turn(start: 6, duration: 5, embedding: [1, 0])] {
            let result = SpeakerClustering.assign([
                turn(start: 0, duration: 5, embedding: [1, 0]), second,
                turn(start: 12, duration: 3, embedding: [0.7, 0.714])
            ], profiles: [VoiceProfile(name: "Анна", samples: [[1, 0]])])
            XCTAssertNotEqual(result[2].speaker, "Анна")
        }
    }

    func testDifferentRecognizedPeopleCannotShareAnAnonymousCluster() {
        let a: [Float] = [1, 0, 0], b: [Float] = [0.65, 0.76, 0]
        let turns = [turn(start: 0, duration: 8, embedding: a),
                     turn(start: 9, duration: 7, embedding: b),
                     turn(start: 17, duration: 3, embedding: [0.8, 0.4, 0.45])]
        let result = SpeakerClustering.assign(turns, profiles: [VoiceProfile(name: "Анна", samples: [a]),
                                                              VoiceProfile(name: "Борис", samples: [b])])
        XCTAssertEqual(result[0].speaker, "Анна")
        XCTAssertEqual(result[1].speaker, "Борис")
        XCTAssertNotEqual(result[2].speaker, "Анна")
        XCTAssertNotEqual(result[2].speaker, "Борис")
    }

    func testShortCleanExcerptCannotSeedALongTurnCluster() {
        var segment = turn(start: 0, duration: 20, embedding: [1, 0])
        segment.embeddingDuration = 1.5
        XCTAssertEqual(SpeakerClustering.assign([segment], profiles: [])[0].speaker, TranscriptSegment.unidentifiedSpeaker)
        segment.embeddingDuration = nil
        XCTAssertEqual(SpeakerClustering.assign([segment], profiles: [])[0].speaker, "Спикер 1")
    }

    func testUniqueClusterKeepsAnAnonymousLabelWhenInheritedNameIsRejected() {
        let weak: [Float] = [0.682, 0.731, 0]
        var mixed = turn(start: 23, duration: 3, embedding: weak)
        mixed.speakerEvidenceIsMixed = true
        let turns = [turn(start: 0, duration: 5, embedding: [1, 0, 0]),
                     turn(start: 6, duration: 5, embedding: [0.985, 0.174, 0]),
                     turn(start: 12, duration: 2, embedding: weak),
                     turn(start: 15, duration: 2, embedding: [0.669, 0.743, 0]),
                     turn(start: 18, duration: 4, embedding: [0, 0, 1]), mixed]
        let result = SpeakerClustering.assign(turns, profiles: [VoiceProfile(name: "Анна", samples: [[1, 0, 0]]),
                                                              VoiceProfile(name: "Борис", samples: [[0, 1, 0]])])
        XCTAssertEqual(result.map(\.speaker), ["Анна", "Анна", "Спикер 1", "Спикер 1", "Спикер 2",
                                               TranscriptSegment.unidentifiedSpeaker])
    }

    func testMatureClusterCannotAbsorbAnUnsupportedSingleVoice() {
        let angles = [0.0, 60, 7, 10, 13, 16, 19]
        let turns = angles.enumerated().map { index, angle in
            let radians = angle * .pi / 180
            return turn(start: Double(index * 12), duration: 8 - Double(index) * 0.4,
                        embedding: [Float(cos(radians)), Float(sin(radians))])
        }
        let result = SpeakerClustering.assign(turns, profiles: [])
        XCTAssertNotEqual(result[0].speaker, result[1].speaker)
    }

    func testAnonymousNamesCannotCollideWithSavedProfileNames() {
        let result = SpeakerClustering.assign([turn(start: 0, duration: 5, embedding: [0, 1])],
                                              profiles: [VoiceProfile(name: "Спикер 1", samples: [[1, 0]])])
        XCTAssertEqual(result[0].speaker, "Спикер 2")
    }

    func testMixedTurnCannotBecomeAnAnchorOrInheritADirectName() {
        var mixed = turn(start: 0, duration: 20, embedding: [1, 0])
        mixed.speakerEvidenceIsMixed = true
        let result = SpeakerClustering.assign([mixed, turn(start: 21, duration: 1, embedding: [1, 0])],
                                              profiles: [VoiceProfile(name: "Анна", samples: [[1, 0]])])
        XCTAssertEqual(result[0].speaker, TranscriptSegment.unidentifiedSpeaker)
        let anonymous = SpeakerClustering.assign([mixed, turn(start: 21, duration: 1, embedding: [1, 0])], profiles: [])
        XCTAssertEqual(anonymous.map(\.speaker), [TranscriptSegment.unidentifiedSpeaker, TranscriptSegment.unidentifiedSpeaker])
    }

    func testOverlappingVariantsCannotUnlockMatureClusterRelaxation() {
        func angled(_ angle: Double, start: Double, duration: Double) -> TranscriptSegment {
            let radians = angle * .pi / 180
            return turn(start: start, duration: duration, embedding: [Float(cos(radians)), Float(sin(radians))])
        }
        let turns = [angled(0, start: 0, duration: 10)] + (0..<6).map {
            angled(10 + Double($0), start: 12, duration: 8 - Double($0) * 0.1)
        } + [angled(60, start: 24, duration: 5)]
        let result = SpeakerClustering.assign(turns, profiles: [])
        XCTAssertNotEqual(result[0].speaker, result.last?.speaker)
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
