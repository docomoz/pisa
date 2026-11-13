import Foundation

/// One segment's deterministic Qwen decodes. All users keep chunk duration 30,
/// repetition penalty 1.1 and temperature 0; varying parameters are in the key.
/// Store raw output so prompt-echo checks and vocabulary rules still run each time.
final class RecognitionDecodeCache<Output> {
    private struct Key: Hashable {
        let pcm: Data
        let context: Data
        let language: Data?
        let maxTokens: Int
    }
    private var outputs: [Key: Output] = [:]
    private(set) var hitCount = 0

    func value(samples: [Float], context: String, language: String?, maxTokens: Int,
               generate: () throws -> Output) rethrows -> Output {
        // Data equality checks every bit, including signed zero and NaN payloads;
        // a hash collision never makes different audio share a result.
        // Swift Strings equate canonically equivalent Unicode spellings, but
        // the tokenizer can distinguish their UTF-8 bytes.
        let key = Key(pcm: samples.withUnsafeBytes { Data($0) }, context: Data(context.utf8),
                      language: language.map { Data($0.utf8) }, maxTokens: maxTokens)
        if let output = outputs[key] {
            hitCount += 1
            return output
        }
        let output = try generate()
        outputs.updateValue(output, forKey: key)
        return output
    }
}
