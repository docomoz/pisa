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
}
