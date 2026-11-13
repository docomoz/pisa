import AVFoundation
import Foundation

enum AudioWindowReader {
    static func read(_ file: AVAudioFile, start: Double, seconds: Double) throws -> [Float] {
        let expected = max(0, Int((seconds * 2000).rounded()))
        let leading = min(expected, max(0, Int((-start * 2000).rounded())))
        let rate = file.processingFormat.sampleRate
        let begin = AVAudioFramePosition(max(0, start) * rate)
        guard leading < expected, begin < file.length else { return Array(repeating: 0, count: expected) }
        file.framePosition = begin
        let frames = AVAudioFrameCount(min(file.length - begin, Int64(ceil(Double(expected - leading) / 2000 * rate))))
        let input = try PCMRead.exact(file, frames: frames)
        let target = AVAudioFormat(standardFormatWithSampleRate: 2000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(expected + 128)) else { throw PisaError.message("Не удалось проверить эхо в записи") }
        var delivered = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .endOfStream; return nil }
            delivered = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        var result = Array(repeating: Float(0), count: leading) + Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        if result.count < expected { result += Array(repeating: 0, count: expected - result.count) }
        return Array(result.prefix(expected))
    }
}
