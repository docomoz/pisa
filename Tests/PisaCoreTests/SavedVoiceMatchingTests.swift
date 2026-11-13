import XCTest
@testable import PisaCore

final class SavedVoiceMatchingTests: XCTestCase {
    private func profile(_ name: String, _ vectors: [[Float]], sameMeeting: Bool = false) -> VoiceProfile {
        var profile = VoiceProfile(name: name, samples: vectors)
        let meeting = UUID()
        profile.examples = vectors.map { vector in
            VoiceExample(file: "\(UUID()).caf", meetingID: sameMeeting ? meeting : UUID(),
                         segmentID: UUID(), embedding: vector).withCurrentEmbedding(vector)
        }
        return profile
    }

    func testAnIsolatedSampleCannotOutvoteTheRestOfItsProfile() {
        let first = profile("First", [[1, 0, 0], [0.8, 0.6, 0], [0, 0, 1]])
        let second = profile("Second", [[0, 0, 1]])
        XCTAssertEqual(VoiceMatcher.identify([0, 0, 1], profiles: [first, second]), "Second")
        XCTAssertNil(VoiceMatcher.identify([0, 0, 1], profiles: [first]))
    }

    func testCorroboratedClipMatchBelowSingleSampleThreshold() {
        let first = profile("First", [[0.6, 0.8, 0, 0], [0.55, 0.6, 0.58, 0]])
        let second = profile("Second", [[0.4, 0, 0, 0.92]])
        XCTAssertEqual(VoiceMatcher.identify([1, 0, 0, 0], profiles: [first, second]), "First")
        var reversed = first
        reversed.examples?.reverse()
        reversed.samples.reverse()
        XCTAssertEqual(VoiceMatcher.identify([1, 0, 0, 0], profiles: [second, reversed]), "First")
    }

    func testWeakEvidenceFromOneMeetingOrFromLegacyEmbeddingsIsInsufficient() {
        let vectors: [[Float]] = [[0.6, 0.8, 0], [0.55, 0.6, 0.58]]
        let sameMeeting = profile("First", vectors, sameMeeting: true)
        let legacy = VoiceProfile(name: "First", samples: vectors)
        XCTAssertNil(VoiceMatcher.identify([1, 0, 0], profiles: [sameMeeting]))
        XCTAssertNil(VoiceMatcher.identify([1, 0, 0], profiles: [legacy]))
    }

    func testACompetitorsSimilarEnrollmentBlocksAnOtherwiseStrongMatch() {
        let first = profile("First", [[0.8, 0.6, 0]])
        let second = profile("Second", [[0.4, 0.8, 0.45]])
        XCTAssertNil(VoiceMatcher.identify([1, 0, 0], profiles: [first, second]))
    }

    func testExcludedExampleCannotMatchThroughItsPairedTrainingVector() {
        var voice = profile("First", [[1, 0]])
        voice.examples?[0].embeddingRevision = 1
        voice.examples?[0].excludedFromRecognition = true
        XCTAssertNil(VoiceMatcher.identify([1, 0], profiles: [voice]))
        voice.samples.append([0, 1])
        XCTAssertEqual(VoiceMatcher.identify([0, 1], profiles: [voice]), "First")
    }

    func testExclusionConsumesOnlyOneCopyOfAnIdenticalVector() {
        var voice = profile("First", [[1, 0], [1, 0]])
        voice.examples?[0].excludedFromRecognition = true
        XCTAssertEqual(VoiceMatcher.identify([1, 0], profiles: [voice]), "First")
        voice.examples?[1].excludedFromRecognition = true
        XCTAssertNil(VoiceMatcher.identify([1, 0], profiles: [voice]))
    }

    func testCorroborationCanBeRequiredEvenForAnExactMatch() {
        let single = VoiceMatcher(profiles: [profile("First", [[1, 0]])])
        XCTAssertEqual(single.identify([1, 0]), "First")
        XCTAssertNil(single.identify([1, 0], requiringCorroboration: true))
        let corroborated = VoiceMatcher(profiles: [profile("First", [[1, 0], [0.8, 0.6]])])
        XCTAssertEqual(corroborated.identify([1, 0], requiringCorroboration: true), "First")
    }
    func testLegacyProvenanceMayRejectEnrollmentWithoutAssigningAName() {
        var legacy = profile("Existing", [[0.6, 0.8, 0], [0.55, 0.6, 0.58]])
        for index in legacy.examples!.indices { legacy.examples![index].embeddingRevision = nil }
        let query: [Float] = [1, 0, 0]
        XCTAssertNil(VoiceMatcher.identify(query, profiles: [legacy]))
        XCTAssertEqual(VoiceMatcher.enrollmentConflict(query, name: "New", profiles: [legacy]), "Existing")
        XCTAssertNil(VoiceMatcher.enrollmentConflict(query, name: "Existing", profiles: [legacy]))
        legacy.examples![1].excludedFromRecognition = true
        XCTAssertNil(VoiceMatcher.enrollmentConflict(query, name: "New", profiles: [legacy]))
    }

}
