import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

/// All inference stays on one actor. A model is released after each meeting.
actor Transcriber {
    private var liveModel: Qwen3ASRModel?
    private var liveActivity: SpeechDetector?
    private var liveVoices: SpeakerEngine?
    private var liveRussian: RussianSpeechRecognizer?
    private var recentLanguageSegments: [TranscriptSegment] = []
    private var previousLiveCacheLimit: Int?

    /// Used by the local synthetic integration fixture to check session reuse.
    func liveModelIdentity() -> ObjectIdentifier? { liveModel.map(ObjectIdentifier.init) }
    func liveRussianModelIdentity() -> ObjectIdentifier? { liveRussian.map(ObjectIdentifier.init) }

    func finishLive() {
        liveModel = nil; liveActivity = nil; liveVoices = nil; liveRussian = nil
        recentLanguageSegments = []
        Memory.clearCache()
        if let limit = previousLiveCacheLimit { Memory.cacheLimit = limit; previousLiveCacheLimit = nil }
    }

    func transcribe(files: [(URL, Double)], modelDirectory: URL, context: String, speakerDirectory: URL, profiles: [VoiceProfile], quiet: Bool = true, live: Bool = false, russianVerification: Bool = true, progress: @escaping @Sendable (Double, String) async -> Void) async throws -> [TranscriptSegment] {
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
        let russian: RussianSpeechRecognizer?
        if !russianVerification { russian = nil }
        else if live, let existing = liveRussian { russian = existing }
        else {
            // Existing/custom installations can still transcribe while the new
            // optional acoustic verifier is unavailable or cannot be loaded.
            russian = try? RussianSpeechRecognizer(directory: speakerDirectory.deletingLastPathComponent().appendingPathComponent(RussianSpeechRecognizer.directoryName))
            if live { liveRussian = russian }
        }
        var segments: [TranscriptSegment] = []
        var backchannels: [UUID: String] = [:]
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
                        if !isMic {
                            // Diarization deliberately ignores very short turns. VAD
                            // can still recover an isolated "да" without inventing a
                            // speaker embedding or recognizing the same turn twice.
                            let speech = activity.regions(samples)
                            let missing = speech.filter { utterance in
                                !regions.contains { $0.start < utterance.end && $0.end > utterance.start }
                            }
                            regions += missing
                            regions.sort { $0.start < $1.start }
                        }
                        regions = regions.flatMap { region -> [VoiceRegion] in
                            let lower = max(0, Int(region.start * 16000))
                            let upper = min(samples.count, Int(region.end * 16000))
                            guard upper > lower else { return [] }
                            return SpeechChunking.ranges(in: samples, range: lower..<upper).map {
                                VoiceRegion(start: Double($0.lowerBound) / 16000, end: Double($0.upperBound) / 16000, embedding: region.embedding)
                            }
                        }
                        for (index, region) in regions.enumerated() {
                            try Task.checkCancellation()
                            // Diarization timestamps can cut through a word. Restore a little
                            // surrounding sound without borrowing from a neighboring turn.
                            let previous = index > 0 ? regions[index - 1].end : 0
                            let next = index + 1 < regions.count ? regions[index + 1].start : duration
                            let leading = min(0.25, max(0, (region.start - previous) / 2))
                            let trailing = min(0.25, max(0, (next - region.end) / 2))
                            let lower = max(0, Int((region.start - leading) * 16000))
                            let upper = min(samples.count, Int((region.end + trailing) * 16000))
                            guard upper > lower else { continue }
                            let regionSamples = Array(samples[lower..<upper])
                            let inferenceStarted = Date()
                            let recognized = try recognize(regionSamples, model: model, russian: russian, vocabulary: context, duration: region.end - region.start)
                            // Give the GPU cooling/foreground headroom between utterances.
                            let thermal = ProcessInfo.processInfo.thermalState
                            if quiet || thermal == .serious || thermal == .critical {
                                let delay = min(3, max(0.1, Date().timeIntervalSince(inferenceStarted) * (quiet ? 0.6 : 0.2)))
                                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            }
                            guard let recognized else { continue }
                            let speaker = isMic ? "Я" : "Собеседники"
                            var segment = TranscriptSegment(start: offset + start + region.start, end: offset + start + region.end, speaker: speaker, text: recognized.text)
                            segment.audioFile = url.lastPathComponent
                            segment.embedding = region.embedding
                            backchannels[segment.id] = recognized.russianBackchannel
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
        if let first = sorted.first, let previous = recentLanguageSegments.first, first.start <= previous.start { recentLanguageSegments = [] }
        let localized = BackchannelLanguage.resolve(sorted, alternatives: backchannels, preceding: live ? recentLanguageSegments : [])
        if live, let end = localized.map(\.end).max() {
            recentLanguageSegments = (recentLanguageSegments + localized).filter { $0.end >= end - 60 }
        }
        return live ? localized : SpeakerClustering.assign(localized, profiles: profiles)
    }

    private struct RecognizedSpeech { var text: String; var russianBackchannel: String? }

    private func recognize(_ samples: [Float], model: Qwen3ASRModel, russian: RussianSpeechRecognizer?, vocabulary: String, duration: Double) throws -> RecognizedSpeech? {
        let audio = MLXArray(samples)
        let maxTokens = min(768, max(64, Int(duration * 16)))
        // On brief replies the vocabulary can be longer than the speech itself.
        let context = duration >= 2 ? vocabulary : ""
        func generate(language: String?, context: String) -> STTOutput {
            model.generate(audio: audio, maxTokens: maxTokens, context: context,
                           language: language, chunkDuration: 30, repetitionPenalty: 1.1)
        }
        func words(_ text: String) -> [Substring] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        }
        let detected = generate(language: nil, context: context)
        let language = detected.language?.lowercased()
        guard language != "none", !detected.text.isEmpty else { return nil }
        let allowed = language == "russian" || language == "english"
        let echoedVocabulary = !context.isEmpty && words(detected.text) == words(context)
        let result: STTOutput
        if !allowed || MeetingSpeechText.containsForeignLetters(detected.text) || echoedVocabulary {
            result = generate(language: allowed ? detected.language : "Russian", context: "")
        } else {
            result = detected
        }
        var text = RecognitionVocabulary.apply(to: result.text.trimmingCharacters(in: .whitespacesAndNewlines), vocabulary: vocabulary)
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
              !MeetingSpeechText.containsForeignLetters(text) else { return nil }
        try Task.checkCancellation()
        if BackchannelLanguage.isAmbiguous(text, duration: duration),
           let alternative = russian?.recognize(samples), BackchannelLanguage.acceptsAlternative(alternative) {
            return RecognizedSpeech(text: text, russianBackchannel: alternative)
        }
        if result.language?.lowercased() == "russian", duration >= 2,
           let hypothesis = russian?.recognize(samples),
           RussianRecognition.shouldRecheck(language: result.language, duration: duration, original: text, alternative: hypothesis) {
            try Task.checkCancellation()
            let checked = generate(language: nil, context: RussianRecognition.context(vocabulary: context, hypothesis: hypothesis))
            let candidate = RecognitionVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines), vocabulary: vocabulary)
            if checked.language?.lowercased() == "russian",
               RussianRecognition.accepts(candidate: candidate, original: text, vocabulary: context) {
                text = candidate
            }
        }
        return RecognizedSpeech(text: text)
    }
}
