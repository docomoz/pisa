import XCTest
@testable import PisaCore

final class SpeakerEmbeddingInputTests: XCTestCase {
    func testSingleChunkUsesOriginalIntegerTurnBeforeTimestampRoundTrip() {
        let original = 32_001..<96_003
        let chunk = Int(Double(original.lowerBound) / 16000 * 16000)..<Int(Double(original.upperBound) / 16000 * 16000)
        XCTAssertEqual(chunk.lowerBound, 32_000)
        let input = SpeakerEmbeddingInput.forChunk(chunk, chunkCount: 1, originalRange: original,
            exclusions: [60_000..<70_000], isMicrophone: false, recoveredSpeech: false)
        XCTAssertEqual(input?.range, original)
        XCTAssertEqual(input?.exclusions, [60_000..<70_000])
    }

    func testSplitTurnUsesExactChunkAndOriginalOverlaps() {
        let samples = [Float](repeating: 0.1, count: 960_000)
        let chunks = SpeechChunking.ranges(in: samples, range: 32_000..<950_000)
        XCTAssertGreaterThan(chunks.count, 1)
        let overlaps = [20_000..<48_000, 500_000..<530_000]
        for chunk in chunks {
            let input = SpeakerEmbeddingInput.forChunk(chunk, chunkCount: chunks.count,
                originalRange: 32_001..<950_000, exclusions: overlaps,
                isMicrophone: false, recoveredSpeech: false)
            XCTAssertEqual(input?.range, chunk)
            XCTAssertEqual(input?.exclusions, overlaps)
        }
    }

    func testMicrophoneAndRecoveredSpeechNeverRequestAnEmbedding() {
        for isMicrophone in [false, true] {
            for recoveredSpeech in [false, true] where isMicrophone || recoveredSpeech {
                for chunkCount in [1, 3] {
                    XCTAssertNil(SpeakerEmbeddingInput.forChunk(0..<160_000, chunkCount: chunkCount,
                        originalRange: 0..<800_000, exclusions: [], isMicrophone: isMicrophone,
                        recoveredSpeech: recoveredSpeech))
                }
            }
        }
    }

    func testMissingDiarizationEvidenceDoesNotInventEmbedding() {
        XCTAssertNil(SpeakerEmbeddingInput.forChunk(0..<160_000, chunkCount: 1,
            originalRange: nil, exclusions: [], isMicrophone: false, recoveredSpeech: false))
    }

    func testMeasuredEmbeddingRangeUsesOnlyTheLongestCleanExcerpt() {
        let input = SpeakerEmbeddingInput(range: 0..<128_000,
            exclusions: [26_000..<64_000, 89_000..<128_000])
        XCTAssertEqual(input.cleanRange(sampleCount: 128_000, minimumSamples: 24_000,
            maximumSamples: 192_000), 0..<26_000)
    }

    func testMeasuredEmbeddingRangeCapsLongAudioAndRejectsShortAudio() {
        let long = SpeakerEmbeddingInput(range: 16_000..<368_000, exclusions: [])
        XCTAssertEqual(long.cleanRange(sampleCount: 384_000, minimumSamples: 24_000,
            maximumSamples: 192_000), 96_000..<288_000)
        let short = SpeakerEmbeddingInput(range: 0..<128_000, exclusions: [20_000..<128_000])
        XCTAssertNil(short.cleanRange(sampleCount: 128_000, minimumSamples: 24_000, maximumSamples: 192_000))
    }

    func testSustainedCompetingSpeechMarksATurnWithACleanExcerptAsMixed() {
        let input = SpeakerEmbeddingInput(range: 0..<320_000, exclusions: [24_000..<320_000])
        XCTAssertEqual(input.cleanRange(sampleCount: 320_000, minimumSamples: 24_000,
            maximumSamples: 192_000), 0..<24_000)
        XCTAssertTrue(input.hasSustainedOverlap(sampleCount: 320_000, sampleRate: 16_000))
    }

    func testCompetingSpeechCountsOnlyUnionInsideTheTurn() {
        let input = SpeakerEmbeddingInput(range: 16_000..<144_000,
            exclusions: [0..<20_000, 34_000..<50_000, 36_000..<49_000, 149_000..<200_000])
        // 1.25 seconds inside the turn, including the duplicated portion once.
        XCTAssertFalse(input.hasSustainedOverlap(sampleCount: 200_000, sampleRate: 16_000))

        let short = SpeakerEmbeddingInput(range: 0..<32_000, exclusions: [16_000..<24_000])
        XCTAssertTrue(short.hasSustainedOverlap(sampleCount: 32_000, sampleRate: 16_000))
    }

    func testEmbeddingEvidenceRoundTripsAndIsOptionalForOlderSegments() throws {
        var segment = TranscriptSegment(start: 0, end: 8, speaker: "Собеседники", text: "Реплика")
        segment.embedding = [1, 0]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let oldData = try encoder.encode(segment)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        XCTAssertNil(encoded["embeddingDuration"])
        XCTAssertNil(encoded["speakerEvidenceIsMixed"])
        XCTAssertEqual(try decoder.decode(TranscriptSegment.self, from: oldData), segment)

        encoded["embeddingDuration"] = 1.625
        encoded["speakerEvidenceIsMixed"] = true
        let newData = try JSONSerialization.data(withJSONObject: encoded)
        let updated = try decoder.decode(TranscriptSegment.self, from: newData)
        XCTAssertEqual(updated.embedding, segment.embedding)
        XCTAssertEqual(updated.embeddingDuration, 1.625)
        XCTAssertEqual(updated.speakerEvidenceIsMixed, true)
        let restored = try JSONSerialization.jsonObject(with: encoder.encode(updated)) as? [String: Any]
        XCTAssertEqual(restored?["embeddingDuration"] as? Double, 1.625)
        XCTAssertEqual(restored?["speakerEvidenceIsMixed"] as? Bool, true)
    }
}
