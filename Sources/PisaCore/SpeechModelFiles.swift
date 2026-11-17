import Foundation

/// Folder checks distinguish the primary recognizer from the contextual verifier.
/// Managed installations additionally verify every file against its pinned hash.
public enum SpeechModelFiles {
    public enum Kind { case parakeet, qwen }
    public static let primaryDirectoryName = "Parakeet-TDT-v3"
    public static let verifierDirectoryName = "Qwen3-ASR"

    public static func isUsable(at url: URL, kind: Kind) -> Bool {
        func exists(_ name: String) -> Bool {
            guard let size = try? url.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
            return size > 0
        }
        guard exists("model.safetensors"),
              let data = try? Data(contentsOf: url.appendingPathComponent("config.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        switch kind {
        case .qwen:
            return object["model_type"] as? String == "qwen3_asr" && exists("tokenizer_config.json") &&
                (exists("tokenizer.json") || exists("vocab.json") && exists("merges.txt"))
        case .parakeet:
            guard (object["target"] as? String)?.hasSuffix(".EncDecRNNTBPEModel") == true,
                  let decoding = object["decoding"] as? [String: Any], decoding["model_type"] as? String == "tdt",
                  let frontend = object["preprocessor"] as? [String: Any],
                  frontend["sample_rate"] as? Int == 16000, frontend["features"] as? Int == 128,
                  let joint = object["joint"] as? [String: Any],
                  let vocabulary = joint["vocabulary"] as? [String] else { return false }
            return vocabulary.contains { token in
                token.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
            }
        }
    }
}
