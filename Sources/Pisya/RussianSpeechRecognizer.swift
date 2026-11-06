import Foundation

/// GigaAM-v3 e2e RNNT supplies an independent acoustic hypothesis on CPU.
/// Owned by Transcriber, including during live windows; no network or text LLM.
final class RussianSpeechRecognizer {
    static let directoryName = "GigaAM-v3"
    private let recognizer: OpaquePointer

    init(directory: URL) throws {
        let files = ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
            .map { directory.appendingPathComponent($0).path }
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            throw PisyaError.message("Не найдена модель русской речи")
        }
        let strings = (files + ["cpu", "nemo_transducer", "greedy_search"]).map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 64
        config.model_config.transducer.encoder = UnsafePointer(strings[0])
        config.model_config.transducer.decoder = UnsafePointer(strings[1])
        config.model_config.transducer.joiner = UnsafePointer(strings[2])
        config.model_config.tokens = UnsafePointer(strings[3])
        config.model_config.provider = UnsafePointer(strings[4])
        config.model_config.model_type = UnsafePointer(strings[5])
        config.model_config.num_threads = 2
        config.decoding_method = UnsafePointer(strings[6])
        config.max_active_paths = 4
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            throw PisyaError.message("Не удалось загрузить модель русской речи")
        }
        self.recognizer = recognizer
    }

    deinit { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

    func recognize(_ samples: [Float]) -> String? {
        recognizeDetailed(samples)?.text
    }

    func recognizeDetailed(_ samples: [Float]) -> RecognitionAcousticResult? {
        guard !samples.isEmpty, samples.count <= 16000 * 30,
              let stream = SherpaOnnxCreateOfflineStream(recognizer) else { return nil }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, Int32(samples.count))
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else { return nil }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        guard let text = result.pointee.text else { return nil }
        let transcript = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        let count = Int(result.pointee.count)
        guard count > 0, count <= 100_000, let times = result.pointee.timestamps,
              let pieces = result.pointee.tokens_arr else {
            return RecognitionAcousticResult(text: transcript, words: [])
        }
        var tokens: [String] = []
        var timestamps: [Double] = []
        tokens.reserveCapacity(count)
        timestamps.reserveCapacity(count)
        for index in 0..<count {
            guard let piece = pieces[index] else { return RecognitionAcousticResult(text: transcript, words: []) }
            tokens.append(String(cString: piece))
            timestamps.append(Double(times[index]))
        }
        let words = RecognitionTimedWords.map(text: transcript, tokens: tokens, timestamps: timestamps,
                                               duration: Double(samples.count) / 16000)
        return RecognitionAcousticResult(text: transcript, words: words)
    }
}

struct RecognitionAcousticResult {
    let text: String
    let words: [RecognitionTimedWord]
}
