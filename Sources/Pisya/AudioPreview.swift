import AVFoundation
import Foundation

enum AudioPreview {
    static func normalizedData(from url: URL, start: Double, end: Double) throws -> Data? {
        let source = try AVAudioFile(forReading: url)
        let rate = source.processingFormat.sampleRate
        let firstFrame = AVAudioFramePosition(start * rate)
        let lastFrame = AVAudioFramePosition(min(Double(source.length), end * rate))
        guard lastFrame > firstFrame else { return nil }
        source.framePosition = firstFrame
        let clip = try PCMRead.exact(source, frames: AVAudioFrameCount(lastFrame - firstFrame))
        guard let samples = clip.floatChannelData else { return nil }
        let channels = Int(clip.format.channelCount)
        let frames = Int(clip.frameLength)

        var energy: Double = 0
        var peak: Float = 0
        for channel in 0..<channels {
            for frame in 0..<frames {
                let sample = samples[channel][frame]
                energy += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
            }
        }
        let rms = sqrt(energy / Double(frames * channels))
        let noiseFloor = pow(10, -55.0 / 20)
        let targetLevel = pow(10, -25.0 / 20)
        let peakCeiling = pow(10, -1.0 / 20)
        guard rms.isFinite, rms > noiseFloor else { return nil }
        let gain = min(10, targetLevel / rms, peakCeiling / Double(peak))
        for channel in 0..<channels {
            for frame in 0..<frames {
                samples[channel][frame] *= Float(gain)
            }
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var settings = clip.format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: temporary, settings: settings)
        try file.write(from: clip)
        file.close()
        return try Data(contentsOf: temporary)
    }
}
