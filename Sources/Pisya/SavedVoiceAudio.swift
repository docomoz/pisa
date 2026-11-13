import AVFoundation
import Foundation

enum SavedVoiceAudio {
    static func isRegularAudio(_ url: URL, in directory: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return url.resolvingSymlinksInPath().deletingLastPathComponent() == directory.resolvingSymlinksInPath()
    }

    static func saveSample(source: URL, start: Double, end: Double, destination: URL, model: URL,
                           extractEmbedding: (@Sendable ([Float]) throws -> [Float]?)?,
                           profiles: [VoiceProfile] = [], name: String = "") throws -> [Float] {
        guard isRegularAudio(source, in: source.deletingLastPathComponent()) else {
            throw PisyaError.message("Аудио этого фрагмента недоступно")
        }
        let file = try AVAudioFile(forReading: source)
        let rate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition((max(0, start) * rate).rounded())
        let endFrame = min(file.length, AVAudioFramePosition((max(0, end) * rate).rounded()))
        guard Double(endFrame - startFrame) / rate >= 2 else {
            throw PisyaError.message("В файле осталось меньше 2 секунд для образца")
        }
        file.framePosition = startFrame
        let buffer = try PCMRead.exact(file, frames: AVAudioFrameCount(endFrame - startFrame))
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var saved = false
        defer { if !saved { try? FileManager.default.removeItem(at: destination) } }
        do {
            let format = buffer.format
            let output = try AVAudioFile(forWriting: destination, settings: format.settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            defer { output.close() }
            try output.write(from: buffer)
        }
        try Task.checkCancellation()
        let embedding: [Float]
        if let extractEmbedding {
            embedding = try self.embedding(from: destination, using: extractEmbedding)
        } else {
            let engine = try SpeakerEngine(directory: model.deletingLastPathComponent())
            embedding = try self.embedding(from: destination) { samples in
                guard !engine.hasConflictingSpeakerActivity(samples) else {
                    throw PisyaError.message("В образце слышны несколько голосов или речь неразборчива. Выберите другой фрагмент либо примените имя без запоминания голоса")
                }
                return engine.vector(samples)
            }
            if VoiceMatcher.enrollmentConflict(embedding, name: name, profiles: profiles) != nil {
                throw PisyaError.message("Образец совпадает с другим сохранённым голосом. Выберите другой фрагмент либо примените имя без запоминания голоса")
            }
        }
        try Task.checkCancellation()
        saved = true
        return embedding
    }

    static func embedding(from url: URL, using vector: ([Float]) throws -> [Float]?) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate.isFinite, rate > 0, Double(file.length) / rate >= 2 else {
            throw PisyaError.message("Для образца нужно не менее 2 секунд аудио")
        }
        let input = try PCMRead.exact(file, frames: AVAudioFrameCount(min(file.length, AVAudioFramePosition(8 * rate))))
        let samples: [Float]
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        if input.format == target, let channel = input.floatChannelData?[0] {
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        } else {
            guard let converter = AVAudioConverter(from: input.format, to: target),
                  let output = AVAudioPCMBuffer(pcmFormat: target,
                      frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) / rate * target.sampleRate) + 64)) else {
                throw PisyaError.message("Не удалось прочитать образец голоса")
            }
            var delivered = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if delivered { status.pointee = .endOfStream; return nil }
                delivered = true
                status.pointee = .haveData
                return input
            }
            if let error { throw error }
            guard let channel = output.floatChannelData?[0] else {
                throw PisyaError.message("Не удалось прочитать образец голоса")
            }
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
        }
        guard let embedding = try vector(samples), VoiceMatcher.similarity(embedding, embedding) > 0 else {
            throw PisyaError.message("Не удалось получить голосовой слепок из выбранного аудио")
        }
        return embedding
    }

    static func refreshedExamples(_ profiles: [VoiceProfile], folder: URL, model: URL) -> [UUID: VoiceExample] {
        guard let engine = try? SpeakerEngine(directory: model.deletingLastPathComponent()) else { return [:] }
        let directory = folder.resolvingSymlinksInPath()
        var refreshed: [UUID: VoiceExample] = [:]
        for example in profiles.flatMap({ $0.examples ?? [] }) where example.needsEmbeddingRefresh {
            if Task.isCancelled { return [:] }
            guard example.file == URL(fileURLWithPath: example.file).lastPathComponent else { continue }
            let url = folder.appendingPathComponent(example.file)
            guard isRegularAudio(url, in: directory) else { continue }
            var unsafe = false
            guard let embedding = try? embedding(from: url, using: { samples in
                unsafe = engine.hasConflictingSpeakerActivity(samples)
                return engine.vector(samples)
            }) else { continue }
            var updated = example.withCurrentEmbedding(embedding)
            updated.excludedFromRecognition = unsafe
            updated.exclusionReason = unsafe ? .overlappingSpeech : nil
            refreshed[example.id] = updated
        }
        // Assess conflicts only after all available clips share fresh vectors.
        // A dominant known voice in a mixed or mislabeled clip must not teach
        // another profile that voice. Audio and the user's labels are retained.
        var evaluated = profiles
        for index in evaluated.indices { _ = evaluated[index].refreshExampleEmbeddings(refreshed) }
        for profile in evaluated {
            let others = VoiceMatcher(profiles: evaluated.filter { $0.name != profile.name })
            for example in profile.examples ?? [] where refreshed[example.id] != nil && example.excludedFromRecognition != true {
                if others.identify(example.embedding, requiringCorroboration: true) != nil {
                    refreshed[example.id]?.excludedFromRecognition = true
                    refreshed[example.id]?.exclusionReason = .identityConflict
                }
            }
        }
        return refreshed
    }
}
