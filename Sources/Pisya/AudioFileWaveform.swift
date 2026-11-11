import Accelerate
import AVFoundation

enum AudioFileWaveform {
    static func load(from sources: [RecordingAudioSource], duration: TimeInterval) async -> [Float] {
        guard !Task.isCancelled, !sources.isEmpty, duration.isFinite, duration > 0 else { return [] }
        let worker = Task.detached(priority: .utility) {
            (try? readPeaks(from: sources, duration: duration)) ?? []
        }
        let peaks = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        return Task.isCancelled ? [] : peaks
    }

    private static func readPeaks(from sources: [RecordingAudioSource], duration: TimeInterval) throws -> [Float] {
        var peaks = Array(repeating: Float.zero, count: 256)
        var readAudio = false
        for source in sources {
            try Task.checkCancellation()
            if (try? mergePeaks(from: source, duration: duration, into: &peaks)) == true {
                readAudio = true
            }
        }
        guard readAudio else { return [] }
        guard let maximum = peaks.max(), maximum > 0 else { return peaks }
        return peaks.map { $0 / maximum }
    }

    private static func mergePeaks(from source: RecordingAudioSource, duration: TimeInterval, into peaks: inout [Float]) throws -> Bool {
        try Task.checkCancellation()
        guard source.offset.isFinite, source.offset < duration else { return false }
        let file = try AVAudioFile(forReading: source.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return false }

        // Each track uses its own sample rate and starts at its playback offset.
        let binCount = peaks.count
        let boundaries = (0...binCount).map { bin -> AVAudioFramePosition in
            let time = duration * (Double(bin) / Double(binCount))
            let frame = ((time - source.offset) * sampleRate).rounded(.up)
            return frame >= Double(frameCount) ? frameCount : AVAudioFramePosition(max(0, frame))
        }
        var position = boundaries[0]
        let end = boundaries[binCount]
        let chunkSize: AVAudioFrameCount = 65_536
        guard position < end,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkSize),
              let channels = buffer.floatChannelData else { return false }
        let channelCount = Int(file.processingFormat.channelCount)
        var bin = 0
        if position > 0 { file.framePosition = position }
        var readAudio = false

        while position < end {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(chunkSize), end - position)))
            guard buffer.frameLength > 0 else { break }
            readAudio = true

            let chunkEnd = position + Int64(buffer.frameLength)
            var offset = 0
            while position < chunkEnd {
                while boundaries[bin + 1] <= position { bin += 1 }
                let rangeLength = min(chunkEnd, boundaries[bin + 1]) - position
                for channel in 0..<channelCount {
                    var peak: Float = 0
                    vDSP_maxmgv(channels[channel].advanced(by: offset), 1, &peak, vDSP_Length(rangeLength))
                    if peak.isFinite {
                        peaks[bin] = max(peaks[bin], peak)
                    }
                }
                position += rangeLength
                offset += Int(rangeLength)
            }
        }
        return readAudio
    }
}
