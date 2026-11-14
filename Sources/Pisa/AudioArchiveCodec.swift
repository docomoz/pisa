import AudioToolbox
import AVFoundation
import Foundation

enum AudioArchiveCodec {
    private static let bitRate = 192_000
    private static let framesPerBuffer: AVAudioFrameCount = 65_536

    /// Writes a verified smaller CAF to an unused path in the caller's private staging directory.
    /// Returns false for unsupported inputs and for files that would grow.
    static func encode(_ source: URL, to destination: URL) async throws -> Bool {
        try Task.checkCancellation()
        guard source.pathExtension.lowercased() == "caf", destination.pathExtension.lowercased() == "caf" else { return false }
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }

        let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: true)
        let original = input.fileFormat.streamDescription.pointee
        let sourceRate = original.mSampleRate
        let channels = original.mChannelsPerFrame
        let frames = input.length
        guard original.mFormatID == kAudioFormatLinearPCM, (1...2).contains(channels), frames > 0,
              let outputRate = encodingRate(for: sourceRate, channels: channels) else { return false }
        let sourceDuration = CMTime(value: frames, timescale: CMTimeScale(sourceRate))
        let encodedDuration = CMTimeConvertScale(sourceDuration, timescale: outputRate, method: .default)
        guard encodedDuration == sourceDuration else { return false }

        var keepOutput = false
        defer { if !keepOutput { try? files.removeItem(at: destination) } }
        try write(input, to: destination, frames: frames, sampleRate: Double(outputRate))
        let originalSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let compressedSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard compressedSize > 0, compressedSize < originalSize else { return false }
        try await validate(destination, duration: encodedDuration, channels: channels)
        try Task.checkCancellation()
        keepOutput = true
        return true
    }

    private static func encodingRate(for sampleRate: Double, channels: AVAudioChannelCount) -> CMTimeScale? {
        // Apple's AAC encoder accepts 192 kbps CBR only at these output rates.
        switch sampleRate {
        case 8_000, 12_000, 16_000, 24_000, 48_000: return 48_000
        case 11_025, 22_050, 44_100: return 44_100
        case 32_000: return channels == 2 ? 32_000 : 48_000
        default: return nil
        }
    }

    private static func write(_ input: AVAudioFile, to destination: URL, frames: AVAudioFramePosition,
                              sampleRate: Double) throws {
        var format = AudioStreamBasicDescription()
        format.mFormatID = kAudioFormatMPEG4AAC
        format.mSampleRate = sampleRate
        format.mChannelsPerFrame = input.processingFormat.channelCount
        var formatSize = streamDescriptionSize
        try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &format))
        var file: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(destination as CFURL, kAudioFileCAFType, &format, nil, 0, &file))
        guard let output = file else { throw ValidationError.format }
        do {
            try configureEncoder(output, inputFormat: input.processingFormat)
            try read(input, frames: frames) {
                try check(ExtAudioFileWrite(output, $0.frameLength, $0.audioBufferList))
            }
        } catch {
            ExtAudioFileDispose(output)
            throw error
        }
        try check(ExtAudioFileDispose(output))
    }

    private static var streamDescriptionSize: UInt32 { UInt32(MemoryLayout<AudioStreamBasicDescription>.size) }

    private static func configureEncoder(_ output: ExtAudioFileRef, inputFormat: AVAudioFormat) throws {
        let propertySize = UInt32(MemoryLayout<UInt32>.size)
        // The Apple software audio codec and Audio Unit manufacturer both use 'appl'.
        var manufacturer = kAudioUnitManufacturer_Apple
        try check(ExtAudioFileSetProperty(output, kExtAudioFileProperty_CodecManufacturer, propertySize, &manufacturer))
        try check(ExtAudioFileSetProperty(output, kExtAudioFileProperty_ClientDataFormat, streamDescriptionSize, inputFormat.streamDescription))
        var encoder: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(output, kExtAudioFileProperty_AudioConverter, &converterSize, &encoder))
        guard let encoder else { throw ValidationError.format }
        var strategy = kAudioCodecBitRateControlMode_Constant
        var rate = UInt32(bitRate)
        var quality = kAudioConverterQuality_Max
        try check(AudioConverterSetProperty(encoder, kAudioCodecPropertyBitRateControlMode, propertySize, &strategy))
        try check(AudioConverterSetProperty(encoder, kAudioConverterEncodeBitRate, propertySize, &rate))
        try check(AudioConverterSetProperty(encoder, kAudioConverterCodecQuality, propertySize, &quality))
        // Resynchronize the CAF stream description with the converter settings.
        var config: UnsafeRawPointer?
        try check(ExtAudioFileSetProperty(output, kExtAudioFileProperty_ConverterConfig, UInt32(MemoryLayout.size(ofValue: config)), &config))
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func validate(_ url: URL, duration: CMTime, channels: AVAudioChannelCount) async throws {
        let encoded = try AVAudioFile(forReading: url)
        let format = encoded.fileFormat.streamDescription.pointee
        guard format.mFormatID == kAudioFormatMPEG4AAC,
              format.mSampleRate == Double(duration.timescale), format.mChannelsPerFrame == channels,
              encoded.length == duration.value else { throw ValidationError.format }
        // Decode every valid frame including the last partial AAC packet.
        try read(encoded, frames: duration.value) { _ in }
        // Playback through AVAsset uses the CAF packet table to trim encoder priming and padding.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1 else { throw ValidationError.timeline }
        let range = try await tracks[0].load(.timeRange)
        guard range.start == .zero, range.duration == duration else {
            throw ValidationError.timeline
        }
    }

    private static func read(_ file: AVAudioFile, frames: AVAudioFramePosition,
                             consume: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: framesPerBuffer) else {
            throw ValidationError.format
        }
        while file.framePosition < frames {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(frames - file.framePosition, Int64(buffer.frameCapacity)))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength > 0 else { throw ValidationError.truncated }
            try consume(buffer)
        }
        guard file.framePosition == frames else { throw ValidationError.truncated }
    }

    private enum ValidationError: Error {
        case format
        case timeline
        case truncated
    }
}
