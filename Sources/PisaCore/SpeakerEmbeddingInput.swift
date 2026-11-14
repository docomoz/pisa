import Foundation

/// Integer audio evidence retained until a recognized remote turn is accepted.
struct SpeakerEmbeddingInput: Equatable {
    var range: Range<Int>
    var exclusions: [Range<Int>]

    static func forChunk(_ chunk: Range<Int>, chunkCount: Int, originalRange: Range<Int>?,
                         exclusions: [Range<Int>], isMicrophone: Bool,
                         recoveredSpeech: Bool) -> SpeakerEmbeddingInput? {
        guard !isMicrophone, !recoveredSpeech, let originalRange else { return nil }
        // The unsplit turn originally used diarization's integer sample range.
        // Reconstructing it from seconds can shift either edge by one sample.
        return SpeakerEmbeddingInput(range: chunkCount > 1 ? chunk : originalRange,
            exclusions: exclusions)
    }

    func cleanRange(sampleCount: Int, minimumSamples: Int, maximumSamples: Int) -> Range<Int>? {
        guard range.count >= minimumSamples else { return nil }
        let clean = SpeechCoverage.uncovered(speech: [range], covered: exclusions,
            sampleCount: sampleCount, minimumPartialLength: minimumSamples)
        guard let longest = clean.max(by: { $0.count < $1.count }), longest.count >= minimumSamples else { return nil }
        let length = min(maximumSamples, longest.count)
        let lower = longest.lowerBound + (longest.count - length) / 2
        return lower..<(lower + length)
    }

    func hasSustainedOverlap(sampleCount: Int, sampleRate: Int) -> Bool {
        let lower = max(0, range.lowerBound)
        let upper = min(sampleCount, range.upperBound)
        guard lower < upper, !exclusions.isEmpty else { return false }
        let turn = lower..<upper
        let clean = SpeechCoverage.uncovered(speech: [turn], covered: exclusions,
            sampleCount: sampleCount, minimumPartialLength: 1)
        let competing = turn.count - clean.reduce(0) { $0 + $1.count }
        return Double(competing) > min(1.5 * Double(sampleRate), 0.20 * Double(turn.count))
    }
}
