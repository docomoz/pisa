import Foundation
import AVFoundation

/// WebRTC AEC3 receives synchronized system playback as its explicit reference.
/// Runs before ASR; originals are never overwritten. Memory is bounded for long calls.
final class AcousticEcho {
    private let processor: OpaquePointer
    static let frameSize = 320 // Two 10 ms WebRTC frames at 16 kHz.
    static let latency = 128 // AEC3 framing, measured by near-only correlation.
    init() throws {
        guard let processor = PisyaEchoCreate() else { throw PisaError.message("Не удалось подготовить подавление эха") }
        self.processor = processor
    }
    deinit { PisyaEchoDestroy(processor) }
    func process(microphone: [Float], reference: [Float]) throws -> [Float] {
        precondition(microphone.count == Self.frameSize && reference.count == Self.frameSize)
        var output = [Float](repeating: 0, count: Self.frameSize)
        try microphone.withUnsafeBufferPointer { mic in try reference.withUnsafeBufferPointer { ref in try output.withUnsafeMutableBufferPointer { out in
            for start in stride(from: 0, to: Self.frameSize, by: 160) {
                if PisyaEchoProcess(processor, mic.baseAddress! + start, ref.baseAddress! + start, out.baseAddress! + start) != 0 {
                    throw PisaError.message("Не удалось обработать микрофон: эхоподавление недоступно")
                }
            }
        } } }
        return output
    }
    static func clean(microphone: URL, offset: Double, reference: URL, referenceOffset: Double,
                      progress: @escaping @Sendable (Double, String) async -> Void) async throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pisa-aec-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let micURL = temporary.appendingPathComponent("mic.caf"), refURL = temporary.appendingPathComponent("ref.caf")
        try await normalize(microphone, to: micURL)
        try await normalize(reference, to: refURL)
        let mic = try AVAudioFile(forReading: micURL), ref = try AVAudioFile(forReading: refURL)
        let result = microphone.deletingPathExtension().appendingPathExtension("clean." + UUID().uuidString + ".caf")
        let staged = temporary.appendingPathComponent("clean.caf")
        let format = mic.processingFormat
        let writer = try AVAudioFile(forWriting: staged, settings: format.settings)
        let alignment = try await EchoAlignment.estimate(microphone: mic, reference: ref, offset: offset, referenceOffset: referenceOffset) { fraction, phase in
            await progress(fraction * 0.25, phase)
        }
        let processor = try AcousticEcho()
        var position: Int64 = 0
        // Offline lookahead keeps small negative clock offsets causal for the adaptive filter.
        func referencePosition(_ position: Int64, delay: Double) -> Int64 {
            EchoAlignment.referencePosition(microphonePosition: position, offset: offset, referenceOffset: referenceOffset, delay: delay)
        }
        var delay = alignment.delay(at: 0)
        // Offline calibration learns the room before the first word is emitted.
        // Clear capture history, then prime the render lookahead from the actual
        // preceding reference. Zeroing both histories loses the first echo's
        // reference and creates a false near-end transient at the file boundary.
        let calibration = min(mic.length, 16000 * 5)
        var training: Int64 = 0
        while training < calibration {
            try Task.checkCancellation()
            _ = try processor.process(microphone: try frame(mic, at: training, count: frameSize), reference: try frame(ref, at: referencePosition(training, delay: delay), count: frameSize))
            training += Int64(frameSize)
        }
        for warmup in stride(from: Int64(-16000), to: 0, by: frameSize) {
            _ = try processor.process(microphone: Array(repeating: 0, count: frameSize),
                                      reference: try frame(ref, at: referencePosition(warmup, delay: delay), count: frameSize))
        }
        while position < mic.length + Int64(latency) {
            try Task.checkCancellation()
            // Playback is submitted 100 ms before its expected microphone echo;
            // change its mapping at that future mic time, not 100 ms too late.
            let nextDelay = alignment.delay(at: Double(position) / 16000 + 0.1)
            if abs(nextDelay - delay) > 0.02 {
                delay = nextDelay
                // Keep the learned room filter and near-end state. Recreating AEC
                // here would train on (and suppress) a quiet boundary utterance.

            }
            let input = try frame(mic, at: position, count: frameSize)
            let playback = try frame(ref, at: referencePosition(position, delay: delay), count: frameSize)
            var output = try processor.process(microphone: input, reference: playback)
            let outputPosition = position - Int64(latency)
            let leadingSkip = Int(max(0, -outputPosition))
            let writePosition = max(0, outputPosition)
            if leadingSkip < frameSize && writePosition < mic.length {
                let count = Int(min(Int64(frameSize - leadingSkip), mic.length - writePosition))
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
                buffer.frameLength = AVAudioFrameCount(count)
                output.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + leadingSkip, count: count) }
                try writer.write(from: buffer)
            }
            position += Int64(frameSize)
            if position % 16000 == 0 { await progress(0.25 + min(1, Double(position) / Double(max(1, mic.length))) * 0.75, "Подавляю эхо · \(timecode(Double(position) / 16000))") }
        }
        writer.close()
        // A successful, complete file replaces the previous derivative in one rename.
        let dataURL = result.appendingPathExtension(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: dataURL) }
        try FileManager.default.copyItem(at: staged, to: dataURL)
        if FileManager.default.fileExists(atPath: result.path) {
            _ = try FileManager.default.replaceItemAt(result, withItemAt: dataURL)
        } else { try FileManager.default.moveItem(at: dataURL, to: result) }
        return result
    }
    static func frame(_ file: AVAudioFile, at position: Int64, count: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let leading = Int(min(Int64(count), max(0, -position)))
        let start = max(0, position)
        var read = 0
        while leading + read < count && start + Int64(read) < file.length {
            file.framePosition = start + Int64(read)
            let n = AVAudioFrameCount(min(Int64(count - leading - read), file.length - file.framePosition))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n)!
            try file.read(into: buffer, frameCount: n)
            guard buffer.frameLength > 0 else { break }
            for i in 0..<Int(buffer.frameLength) { result[leading + read + i] = buffer.floatChannelData![0][i] }
            read += Int(buffer.frameLength)
        }
        return result
    }
    private static func normalize(_ source: URL, to destination: URL) async throws {
        let file = try AVAudioFile(forReading: source)
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else { throw PisaError.message("Не удалось подготовить аудио для подавления эха") }
        let writer = try AVAudioFile(forWriting: destination, settings: target.settings)
        defer { writer.close() }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16000)!
            var conversionError: NSError?, readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { requested, inputStatus in
                guard file.framePosition < file.length else { inputStatus.pointee = .endOfStream; return nil }
                do {
                    let count = AVAudioFrameCount(min(Int64(requested), file.length - file.framePosition))
                    let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                    try file.read(into: input, frameCount: count)
                    inputStatus.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input
                } catch { readError = error; inputStatus.pointee = .endOfStream; return nil }
            }
            if let readError { throw readError }; if let conversionError { throw conversionError }
            if output.frameLength > 0 { try writer.write(from: output) }
            if status == .endOfStream { break }
        }
        // Drain the resampler tail after its final input buffer.
        while true {
            let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16000)!
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
            if let error { throw error }
            if output.frameLength > 0 { try writer.write(from: output) }
            if status == .endOfStream || output.frameLength == 0 { break }
        }
    }
}
