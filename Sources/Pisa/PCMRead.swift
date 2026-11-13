import AVFoundation

/// AVAudioFile may return less than requested before EOF. Never skip that tail.
enum PCMRead {
    static func exact(_ file: AVAudioFile, frames requested: AVAudioFrameCount, maxChunk: AVAudioFrameCount = 65536) throws -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount(min(Int64(requested), max(0, file.length - file.framePosition)))
        guard count > 0, maxChunk > 0, let output = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw PisaError.message("В аудиофайле недостаточно данных") }
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        let bytesPerFrame = Int(file.processingFormat.streamDescription.pointee.mBytesPerFrame)
        var read: AVAudioFrameCount = 0
        while read < count {
            let n = min(maxChunk, count - read)
            guard let part = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: n) else { throw PisaError.message("Не удалось прочитать аудио") }
            try file.read(into: part, frameCount: n)
            guard part.frameLength > 0 else { throw PisaError.message("Аудиофайл прервался до конца выбранного фрагмента") }
            let source = UnsafeMutableAudioBufferListPointer(part.mutableAudioBufferList)
            for channel in source.indices {
                guard let src = source[channel].mData, let dst = destination[channel].mData else { throw PisaError.message("Аудиофайл не содержит данных канала") }
                memcpy(dst.advanced(by: Int(read) * bytesPerFrame), src, Int(part.frameLength) * bytesPerFrame)
            }
            read += part.frameLength
        }
        output.frameLength = read
        return output
    }
}
