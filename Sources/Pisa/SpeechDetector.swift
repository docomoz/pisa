import Foundation
import AVFoundation

/// Lightweight VAD keeps residual noise/silence away from a generative recognizer.
/// One CPU thread; no speaker embeddings or diarization of the microphone track.
final class SpeechDetector {
    private let detector: OpaquePointer
    private let leadingContext = 4096
    init() throws {
        guard let model = Bundle.main.url(forResource: "silero_vad", withExtension: "onnx") else { throw PisaError.message("В приложении отсутствует модель определения речи") }
        var instance: OpaquePointer?
        model.path.withCString { path in "cpu".withCString { provider in
            var config = SherpaOnnxVadModelConfig()
            config.silero_vad.model = path
            config.silero_vad.threshold = 0.5
            config.silero_vad.min_silence_duration = 0.5
            config.silero_vad.min_speech_duration = 0.1
            config.silero_vad.window_size = 512
            // Recognition chooses its own quiet boundaries inside this bounded
            // region. A VAD-forced 24 s cut used to bisect words before ASR saw them.
            config.silero_vad.max_speech_duration = 60
            config.sample_rate = 16000; config.num_threads = 1; config.provider = provider
            instance = SherpaOnnxCreateVoiceActivityDetector(&config, 90)
        } }
        guard let instance else { throw PisaError.message("Не удалось загрузить модель определения речи") }
        detector = instance
    }
    deinit { SherpaOnnxDestroyVoiceActivityDetector(detector) }
    /// Run one continuous VAD stream across the entire file, so input chunk boundaries
    /// cannot split a short answer into two rejected fragments. Only time ranges remain.
    func regions(in url: URL) throws -> [VoiceRegion] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw PisaError.message("Не удалось прочитать микрофонную дорожку") }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        startStream()
        var result: [VoiceRegion] = []
        while true {
            try Task.checkCancellation()
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16000)!
            var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, state in
                guard file.framePosition < file.length else { state.pointee = .endOfStream; return nil }
                do {
                    let count = AVAudioFrameCount(min(Int64(requested), file.length - file.framePosition))
                    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                    try file.read(into: input, frameCount: count)
                    state.pointee = input.frameLength > 0 ? .haveData : .endOfStream; return input
                } catch { readError = error; state.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }; if let conversionError { throw conversionError }
            if output.frameLength > 0 {
                for start in stride(from: 0, to: Int(output.frameLength), by: 512) {
                    let count = min(512, Int(output.frameLength) - start)
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, output.floatChannelData![0].advanced(by: start), Int32(count))
                    result += drain(duration: duration)
                }
            }
            if status == .endOfStream { break }
        }
        finishStream()
        result += drain(duration: duration)
        // Forced long-speech splits may overlap only because of padding. Divide the
        // shared padding once, preserving coverage without transcribing it twice.
        if result.count > 1 {
            for i in 1..<result.count where result[i - 1].end > result[i].start {
                let boundary = (result[i - 1].end + result[i].start) / 2
                result[i - 1].end = boundary; result[i].start = boundary
            }
        }
        return result
    }
    private func drain(duration: Double) -> [VoiceRegion] {
        var result: [VoiceRegion] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(detector) else { break }
            let start = max(0, Double(segment.pointee.start - Int64(leadingContext)) / 16000 - 0.15)
            let end = min(duration, Double(segment.pointee.start + Int64(segment.pointee.n) - Int64(leadingContext)) / 16000 + 0.15)
            if end > start { result.append(VoiceRegion(start: start, end: end, embedding: nil)) }
            SherpaOnnxDestroySpeechSegment(segment); SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return result
    }
    func regions(_ samples: [Float]) -> [VoiceRegion] {
        startStream()
        for start in stride(from: 0, to: samples.count, by: 512) {
            let chunk = Array(samples[start..<min(samples.count, start + 512)])
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, chunk, Int32(chunk.count))
        }
        finishStream()
        var regions: [VoiceRegion] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            guard let segment = SherpaOnnxVoiceActivityDetectorFront(detector) else { break }
            let start = max(0, Double(segment.pointee.start - Int64(leadingContext)) / 16000 - 0.15)
            let end = min(Double(samples.count) / 16000, Double(segment.pointee.start + Int64(segment.pointee.n) - Int64(leadingContext)) / 16000 + 0.15)
            if end > start {
                if let previous = regions.last, previous.end >= start {
                    regions[regions.count - 1].end = end
                } else { regions.append(VoiceRegion(start: start, end: end, embedding: nil)) }
            }
            SherpaOnnxDestroySpeechSegment(segment)
            SherpaOnnxVoiceActivityDetectorPop(detector)
        }
        return regions
    }
    private func startStream() {
        SherpaOnnxVoiceActivityDetectorReset(detector)
        // Recurrent VAD needs quiet context before a short first utterance. This
        // virtual padding never enters the audio file or transcript timeline.
        let silence = [Float](repeating: 0, count: 512)
        for _ in 0..<(leadingContext / 512) { SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, silence, 512) }
    }
    private func finishStream() {
        let silence = [Float](repeating: 0, count: 512)
        for _ in 0..<16 { SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, silence, 512) }
        SherpaOnnxVoiceActivityDetectorFlush(detector)
    }
}
