import XCTest
@testable import PisyaCore

final class VoiceExampleMigrationTests: XCTestCase {
    func testRefreshPreservesPersistedExclusion() throws {
        var example = VoiceExample(file: "sample.caf", meetingID: UUID(), segmentID: UUID(), embedding: [1, 0])
        example.embeddingRevision = 1
        example.excludedFromRecognition = true
        var profile = VoiceProfile(name: "Анна", samples: [[1, 0]])
        profile.examples = [example]

        XCTAssertTrue(example.needsEmbeddingRefresh)
        XCTAssertTrue(profile.refreshExampleEmbeddings([example.id: example.withCurrentEmbedding([0, 1])]))
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.examples?.first?.excludedFromRecognition, true)
        XCTAssertEqual(decoded.examples?.first?.needsEmbeddingRefresh, false)
        XCTAssertNil(VoiceMatcher.identify([0, 1], profiles: [decoded]))
    }

    func testRenamedProfileCanRevalidateAnIdentityConflictWithoutReenablingNoisyClips() throws {
        func excluded(_ reason: VoiceExample.ExclusionReason?, vector: [Float]) -> VoiceExample {
            var example = VoiceExample(file: "\(UUID()).caf", meetingID: UUID(), segmentID: UUID(), embedding: vector)
                .withCurrentEmbedding(vector)
            example.excludedFromRecognition = true
            example.exclusionReason = reason
            return example
        }
        let identity = excluded(.identityConflict, vector: [1, 0, 0])
        let overlap = excluded(.overlappingSpeech, vector: [0, 1, 0])
        let legacy = excluded(nil, vector: [0, 0, 1])
        var profile = VoiceProfile(name: "Уточнённое имя", samples: [identity.embedding, overlap.embedding, legacy.embedding])
        profile.examples = [identity, overlap, legacy]

        profile.requestIdentityRevalidation()
        let pending = try XCTUnwrap(profile.examples?.first)
        XCTAssertTrue(pending.needsEmbeddingRefresh)
        XCTAssertEqual(pending.excludedFromRecognition, true)
        XCTAssertEqual(pending.exclusionReason, .identityConflict)
        XCTAssertEqual(profile.examples?.dropFirst().map { $0 }, [overlap, legacy])
        XCTAssertNil(VoiceMatcher.identify(identity.embedding, profiles: [profile]))

        var corrected = pending.withCurrentEmbedding(identity.embedding)
        XCTAssertEqual(corrected.exclusionReason, .identityConflict)
        corrected.excludedFromRecognition = false
        corrected.exclusionReason = nil
        XCTAssertTrue(profile.refreshExampleEmbeddings([corrected.id: corrected]))
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(VoiceMatcher.identify(identity.embedding, profiles: [decoded]), profile.name)
        XCTAssertNil(VoiceMatcher.identify(overlap.embedding, profiles: [decoded]))
        XCTAssertNil(VoiceMatcher.identify(legacy.embedding, profiles: [decoded]))
        XCTAssertEqual(decoded.examples?.dropFirst().map { $0 }, [overlap, legacy])
    }

    func testRefreshReplacesOnlyPairedTrainingAndPreservesRenamedProfile() throws {
        let first = VoiceExample(file: "first.caf", meetingID: UUID(), segmentID: UUID(), embedding: [1, 0])
        let missing = VoiceExample(file: "missing.caf", meetingID: UUID(), segmentID: UUID(), embedding: [1, 0])
        let merged = VoiceExample(file: "merged.caf", meetingID: UUID(), segmentID: UUID(), embedding: [0, 1])
        let deleted = VoiceExample(file: "deleted.caf", meetingID: UUID(), segmentID: UUID(), embedding: [1, 1])
        var profile = VoiceProfile(name: "Новое имя", samples: [[1, 0], [1, 0], [-1, 0]])
        profile.examples = [first, missing, merged]

        let data = try JSONEncoder().encode(profile)
        var decoded = try JSONDecoder().decode(VoiceProfile.self, from: data)
        XCTAssertNil(decoded.examples?.first?.embeddingRevision)
        XCTAssertTrue(decoded.refreshExampleEmbeddings([
            first.id: first.withCurrentEmbedding([0, 1]),
            merged.id: merged.withCurrentEmbedding([0, -1]),
            deleted.id: deleted.withCurrentEmbedding([1, -1])
        ]))

        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, "Новое имя")
        XCTAssertEqual(decoded.examples?.map(\.id), [first.id, missing.id, merged.id])
        XCTAssertEqual(decoded.examples?.map(\.file), ["first.caf", "missing.caf", "merged.caf"])
        XCTAssertEqual(decoded.examples?.map(\.embedding), [[0, 1], [1, 0], [0, -1]])
        XCTAssertEqual(decoded.samples, [[0, 1], [1, 0], [-1, 0], [0, -1]])
        XCTAssertNil(decoded.examples?[1].embeddingRevision)
        XCTAssertFalse(decoded.refreshExampleEmbeddings([first.id: first.withCurrentEmbedding([1, 1])]))
        XCTAssertEqual(decoded.examples?.first?.embedding, [0, 1])
    }
}
