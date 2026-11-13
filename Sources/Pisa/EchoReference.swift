import AVFoundation

/// Reads only the current region, keeping memory bounded for long meetings.
struct EchoReference {
    let url: URL
    let offset: Double
    func matches(_ microphone: [Float], at start: Double) -> Bool {
        do {
            let file = try AVAudioFile(forReading: url)
            let begin = start - offset - 0.35
            let padding = max(0, Int((-begin * 16000).rounded()))
            guard padding < microphone.count else { return false }
            let format = file.processingFormat
            file.framePosition = AVAudioFramePosition(max(0, begin) * format.sampleRate)
            let duration = Double(microphone.count + 5600 - padding) / 16000
            let frames = AVAudioFrameCount(ceil(duration * format.sampleRate))
            guard file.length - file.framePosition >= frames,
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: target) else { return false }
            // CAF reads can be shorter than requested, even before EOF.
            var read: AVAudioFrameCount = 0
            while read < frames {
                guard let part = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames - read) else { return false }
                try file.read(into: part, frameCount: frames - read)
                guard part.frameLength > 0, let source = part.floatChannelData, let dest = input.floatChannelData else { return false }
                for ch in 0..<Int(format.channelCount) {
                    for i in 0..<Int(part.frameLength) { dest[ch][(Int(read) + i) * input.stride] = source[ch][i * part.stride] }
                }
                read += part.frameLength
            }
            input.frameLength = read
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(microphone.count + 5600 + 64)) else { return false }
            var delivered = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if delivered { status.pointee = .endOfStream; return nil }
                delivered = true; status.pointee = .haveData; return input
            }
            guard error == nil, let data = output.floatChannelData?[0] else { return false }
            return EchoDetector.isEcho(microphone: microphone, reference: Array(repeating: 0, count: padding) + Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength))))
        } catch { return false }
    }
}
