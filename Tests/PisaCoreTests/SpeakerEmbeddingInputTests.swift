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
}
