import AVFoundation
import Foundation

enum PisyaError: Error { case message(String) }
@main struct Probe {
    static func main() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("test-mic.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let writer = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = 24000
        for i in 0..<24000 { buffer.floatChannelData![0][i] = Float(i) / 24000 }
        try writer.write(from: buffer)
        let boundary = CaptureTrackBoundary(url: source, offset: 0, frames: writer.length, sampleRate: 24000)
        try writer.write(from: buffer) // Snapshot must be limited to the published boundary.
        let chunks = try CaptureWindow.copy([boundary], start: 0.5, end: 1.5, directory: directory)
        precondition(chunks.count == 1 && chunks[0].offset == 0.5 && chunks[0].original == source)
        let reader = try AVAudioFile(forReading: chunks[0].url)
        precondition(reader.length == 12000)
        let result = AVAudioPCMBuffer(pcmFormat: reader.processingFormat, frameCapacity: 12000)!
        try reader.read(into: result)
        precondition(abs(result.floatChannelData![0][0] - 0.5) < 0.0001)
        precondition(abs(result.floatChannelData![0][11999] - Float(23999)/24000) < 0.0001)
        let missing = CaptureTrackBoundary(url: directory.appendingPathComponent("missing-remote.caf"), offset: 0, frames: 24000, sampleRate: 24000)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        do {
            _ = try CaptureWindow.copy([boundary, missing], start: 0, end: 1, directory: directory)
            preconditionFailure("A failed track must fail the entire snapshot")
        } catch {}
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        precondition(before == after)
        writer.close()

        let intSource = directory.appendingPathComponent("integer-remote.caf")
        let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48000, channels: 1, interleaved: true)!
        let intWriter = try AVAudioFile(forWriting: intSource, settings: intFormat.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let intBuffer = AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 48000)!
        intBuffer.frameLength = 48000
        for index in 0..<48000 { intBuffer.int16ChannelData![0][index] = 8192 }
        try intWriter.write(from: intBuffer)
        let intBoundary = CaptureTrackBoundary(url: intSource, offset: 0.25, frames: intWriter.length, sampleRate: 48000)
        let intFiles = try CaptureWindow.copy([intBoundary], start: 0.5, end: 1, directory: directory)
        precondition(intFiles.count == 1 && intFiles[0].offset == 0.5 && intFiles[0].original == intSource)
        let intReader = try AVAudioFile(forReading: intFiles[0].url)
        precondition(intReader.length == 24000)
        let intResult = AVAudioPCMBuffer(pcmFormat: intReader.processingFormat, frameCapacity: 24000)!
        try intReader.read(into: intResult)
        precondition(abs(intResult.floatChannelData![0][0] - 0.25) < 0.0001)
        intWriter.close()
        print("growing CAF snapshots: Float32/Int16, published frames, offsets, source mapping and failed-copy cleanup verified")
    }
}
