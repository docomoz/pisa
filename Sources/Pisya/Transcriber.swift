import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

/// All inference stays on one actor. A model is released after each meeting.
actor Transcriber {
    private var liveModel: Qwen3ASRModel?
    private var liveActivity: SpeechDetector?
    private var liveVoices: SpeakerEngine?
    private var previousLiveCacheLimit: Int?

    /// Used by the local synthetic integration fixture to check session reuse.
    func liveModelIdentity() -> ObjectIdentifier? { liveModel.map(ObjectIdentifier.init) }

    func finishLive() {
        liveModel = nil; liveActivity = nil; liveVoices = nil
        Memory.clearCache()
        if let limit = previousLiveCacheLimit { Memory.cacheLimit = limit; previousLiveCacheLimit = nil }
    }

    func transcribe(files: [(URL, Double)], modelDirectory: URL, context: String, speakerDirectory: URL, profiles: [VoiceProfile], quiet: Bool = true, live: Bool = false, progress: @escaping @Sendable (Double, String) async -> Void) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path), FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.safetensors").path) else { throw PisyaError.message("Выберите папку модели Qwen3-ASR с config.json и model.safetensors") }
        let previousCacheLimit = Memory.cacheLimit
        if live && previousLiveCacheLimit == nil { previousLiveCacheLimit = previousCacheLimit }
        Memory.cacheLimit = 256 * 1024 * 1024
        defer { if !live { Memory.clearCache(); Memory.cacheLimit = previousCacheLimit } }
        var generated: URL?
        var keepGenerated = false
        defer { if !keepGenerated, let generated { try? FileManager.default.removeItem(at: generated) } }
        var preparedFiles = files.filter { !$0.0.lastPathComponent.contains(".clean.") }
        if let mic = preparedFiles.first(where: { $0.0.lastPathComponent.contains("-mic.") }),
           let remote = preparedFiles.first(where: { $0.0.lastPathComponent.contains("-remote.") }) {
            await progress(0, "Подготавливаю подавление эха")
            let clean = try await AcousticEcho.clean(microphone: mic.0, offset: mic.1, reference: remote.0, referenceOffset: remote.1) { fraction, phase in
                await progress(fraction * 0.12, phase)
            }
            generated = clean
            preparedFiles = preparedFiles.map { $0.0 == mic.0 ? (clean, mic.1) : $0 }
        }
        await progress(0.12, "Загружаю модель в память")
        let activity: SpeechDetector
        if let existing = live ? liveActivity : nil { activity = existing } else { activity = try SpeechDetector(); if live { liveActivity = activity } }
        let model: Qwen3ASRModel
        if let existing = live ? liveModel : nil { model = existing } else { model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory); if live { liveModel = model } }
        let voices: SpeakerEngine?
        if live, let existing = liveVoices { voices = existing }
        else { voices = FileManager.default.fileExists(atPath: speakerDirectory.appendingPathComponent("titanet.onnx").path) ? try SpeakerEngine(directory: speakerDirectory) : nil; if live { liveVoices = voices } }
        var segments: [TranscriptSegment] = []
        for (fileIndex, item) in preparedFiles.sorted(by: { !$0.0.lastPathComponent.contains("-mic.") && $1.0.lastPathComponent.contains("-mic.") }).enumerated() {
            try Task.checkCancellation()
            let (url, offset) = item
            let file = try AVAudioFile(forReading: url)
            let sourceFormat = file.processingFormat
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw PisyaError.message("Не удалось прочитать формат аудио") }
            let total = file.length
            let isMic = url.lastPathComponent.contains("-mic.")
            let ranges: [VoiceRegion]
            if isMic { ranges = try activity.regions(in: url) }
            else {
                let seconds = Double(total) / sourceFormat.sampleRate
                ranges = stride(from: 0.0, to: seconds, by: 60).map { VoiceRegion(start: $0, end: min(seconds, $0 + 60), embedding: nil) }
            }
            for range in ranges {
                try Task.checkCancellation()
                var position = AVAudioFramePosition(range.start * sourceFormat.sampleRate)
                file.framePosition = position
                let frames = AVAudioFrameCount(min(total - position, Int64(ceil((range.end - range.start) * sourceFormat.sampleRate))))
                let input = try PCMRead.exact(file, frames: frames)
                let outputFrames = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / sourceFormat.sampleRate) + 64)
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputFrames) else { throw PisyaError.message("Не удалось преобразовать аудио") }
                var delivered = false; var conversionError: NSError?
                converter.reset()
                converter.convert(to: output, error: &conversionError) { _, status in
                    if delivered { status.pointee = .endOfStream; return nil }
                    delivered = true; status.pointee = .haveData; return input
                }
                if let conversionError { throw conversionError }
                let start = Double(position) / sourceFormat.sampleRate
                let duration = Double(input.frameLength) / sourceFormat.sampleRate
                if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
                    let energy = samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)
                    if energy > 0.000001 {
                        var regions = isMic ? [VoiceRegion(start: 0, end: duration, embedding: voices?.vector(samples))] : voices?.regions(samples) ?? []
                        if !isMic && voices == nil { regions = activity.regions(samples) }
                        regions = regions.flatMap { region -> [VoiceRegion] in
                            stride(from: region.start, to: region.end, by: 24).map {
                                VoiceRegion(start: $0, end: min($0 + 24, region.end), embedding: region.embedding)
                            }
                        }
                        for region in regions {
                            try Task.checkCancellation()
                            let lower = max(0, Int(region.start * 16000))
                            let upper = min(samples.count, Int(region.end * 16000))
                            guard upper > lower else { continue }
                            let regionSamples = Array(samples[lower..<upper])
                            let inferenceStarted = Date()
                            // Short residual/noisy mic spans must not be prompted into
                            // "hearing" the vocabulary. Actual words still go through ASR.
                            let result = model.generate(audio: MLXArray(regionSamples), maxTokens: min(768, max(64, Int((region.end - region.start) * 16))), context: isMic ? "" : context, language: isMic ? nil : "Russian", chunkDuration: 24, repetitionPenalty: 1.1)
                            // Give the GPU cooling/foreground headroom between utterances.
                            let thermal = ProcessInfo.processInfo.thermalState
                            if quiet || thermal == .serious || thermal == .critical {
                                let delay = min(3, max(0.1, Date().timeIntervalSince(inferenceStarted) * (quiet ? 0.6 : 0.2)))
                                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            }
                            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty, result.language?.lowercased() != "none" else { continue }
                            let speaker = isMic ? "Я" : "Собеседники"
                            var segment = TranscriptSegment(start: offset + start + region.start, end: offset + start + region.end, speaker: speaker, text: text)
                            segment.audioFile = url.lastPathComponent
                            segment.embedding = region.embedding
                            segments.append(segment)

                        }
                    }
                }
                position += AVAudioFramePosition(input.frameLength)
                let fraction = (Double(fileIndex) + Double(position) / Double(max(1, total))) / Double(preparedFiles.count)
                await progress(0.12 + fraction * 0.88, "Распознаю · \(timecode(start + duration))")
            }
        }
        keepGenerated = generated.map { url in segments.contains { $0.audioFile == url.lastPathComponent } } ?? false
        let sorted = segments.sorted { $0.start < $1.start }
        return live ? sorted : SpeakerClustering.assign(sorted, profiles: profiles)
    }
}
