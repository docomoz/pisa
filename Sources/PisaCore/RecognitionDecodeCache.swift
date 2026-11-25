import Foundation

/// A bounded cache for deterministic Qwen calls made by one recognition session.
/// Raw output is replayed through the same prompt-echo and vocabulary checks.
final class RecognitionDecodeCache<Input, Output> {
    private struct Result {
        let context: Data
        let language: Data?
        let maxTokens: Int
        let completedTokens: Int?
        let output: Output
    }

    private final class Clip {
        let pcm: Data
        let sampleCost: Int
        let input: Input
        var results: [Result] = []

        init(pcm: Data, sampleCost: Int, input: Input) {
            self.pcm = pcm
            self.sampleCost = sampleCost
            self.input = input
        }
    }

    // A short input is padded by the encoder. Charge at least one second of
    // the sample budget per clip in addition to the limit on retained wrappers.
    private let sampleRate = 16_000
    private let sampleBudget = 120 * 16_000
    private let clipLimit = 32
    private let resultLimit = 8
    private var clips: [Clip] = []
    private var retainedSamples = 0
    private(set) var hitCount = 0

    func value(samples: [Float], context: String, language: String?, maxTokens: Int,
               prepare: () -> Input, generate: (Input) throws -> Output,
               completedTokens: (Output) -> Int?) rethrows -> Output {
        // An oversize recording must not evict every reusable short reply.
        guard samples.count <= sampleBudget else { return try generate(prepare()) }

        // Exact bytes distinguish signed zero and NaN payloads, as well as
        // canonically equivalent Unicode strings with different tokenizer input.
        let pcm = samples.withUnsafeBytes { Data($0) }
        let promptBytes = Data(context.utf8)
        let languageBytes = language.map { Data($0.utf8) }
        let clip: Clip
        if let index = clips.firstIndex(where: { $0.pcm == pcm }) {
            clip = clips.remove(at: index)
            clips.append(clip)
            if let index = clip.results.firstIndex(where: { result in
                guard result.context == promptBytes, result.language == languageBytes else { return false }
                if result.maxTokens == maxTokens { return true }
                // The greedy sequence up to its stop token is independent of
                // the limit. A clipped result can only serve its original cap.
                return result.completedTokens.map { $0 < maxTokens } ?? false
            }) {
                let result = clip.results.remove(at: index)
                clip.results.append(result)
                hitCount += 1
                return result.output
            }
        } else {
            let cost = max(sampleRate, samples.count)
            while clips.count >= clipLimit || retainedSamples + cost > sampleBudget {
                retainedSamples -= clips.removeFirst().sampleCost
            }
            clip = Clip(pcm: pcm, sampleCost: cost, input: prepare())
            clips.append(clip)
            retainedSamples += cost
        }

        let output = try generate(clip.input)
        let count = completedTokens(output).flatMap { $0 >= 0 && $0 < maxTokens ? $0 : nil }
        if clip.results.count >= resultLimit { clip.results.removeFirst() }
        clip.results.append(Result(context: promptBytes, language: languageBytes, maxTokens: maxTokens,
                                   completedTokens: count, output: output))
        return output
    }
}
