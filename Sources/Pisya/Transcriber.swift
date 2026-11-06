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
    private var vocabularySource: String?
    private var spokenVocabulary = SpokenVocabulary("")

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
        if vocabularySource != context {
            let pronunciations = Bundle.main.url(forResource: "cmudict", withExtension: "dict")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            spokenVocabulary = SpokenVocabulary(context, pronunciations: pronunciations)
            vocabularySource = context
        }
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
            if isMic {
                // The microphone has one speaker. Brief VAD gaps inside a name
                // or a foreign term must not split that word between decodes.
                let detected = try activity.regions(in: url).map {
                    Int(($0.start * 16000).rounded())..<Int(($0.end * 16000).rounded())
                }
                ranges = SpeechCoverage.joinNearby(detected, maximumGap: 12_800, maximumLength: 960_000,
                    shortTurnLength: 48_000, maximumShortTurnGap: 4_000).map {
                    VoiceRegion(start: Double($0.lowerBound) / 16000, end: Double($0.upperBound) / 16000, embedding: nil)
                }
            }
            else {
                let seconds = Double(total) / sourceFormat.sampleRate
                ranges = stride(from: 0.0, to: seconds, by: 60).map { VoiceRegion(start: $0, end: min(seconds, $0 + 60), embedding: nil) }
            }
            for (rangeIndex, range) in ranges.enumerated() {
                try Task.checkCancellation()
                let sampleRate = sourceFormat.sampleRate
                let lower = max(0, min(Int(total), Int(range.start * sampleRate)))
                let upper = max(lower, min(Int(total), Int(ceil(range.end * sampleRate))))
                guard upper > lower else { continue }
                let original = lower..<upper
                let padding = Int(0.25 * sampleRate)
                let readRange: Range<Int>
                if isMic {
                    let previousEnd = rangeIndex > 0
                        ? Int(ceil(ranges[..<rangeIndex].map(\.end).max()! * sampleRate)) : lower - 2 * padding
                    let nextStart = rangeIndex + 1 < ranges.count
                        ? Int(ranges[rangeIndex + 1].start * sampleRate) : upper + 2 * padding
                    readRange = SpeechCoverage.safeExpansion(region: original, base: original, previousEnd: previousEnd,
                        nextStart: nextStart, sampleCount: Int(total), maximumPadding: padding) ?? original
                } else { readRange = original }
                var position = AVAudioFramePosition(readRange.lowerBound)
                file.framePosition = position
                let frames = AVAudioFrameCount(readRange.count)
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
                        var regions = isMic
                            ? [VoiceRegion(start: max(0, range.start - start), end: min(duration, range.end - start), embedding: voices?.vector(samples))]
                            : voices?.regions(samples) ?? []
                        if !isMic {
                            // Diarization deliberately ignores very short turns. VAD
                            // can still recover an isolated "да" without inventing a
                            // speaker embedding or recognizing the same turn twice.
                            let speech = activity.regions(samples)
                            func sampleRange(_ region: VoiceRegion) -> Range<Int> {
                                Int((region.start * 16000).rounded())..<Int((region.end * 16000).rounded())
                            }
                            // Reserve the audio padding already used to decode
                            // each speaker turn. Recovered gaps must not steal
                            // its syllables or change its recognition context.
                            let covered = regions.enumerated().map { index, region in
                                let previous = regions[..<index].map(\.end).max() ?? 0
                                let next = index + 1 < regions.count ? regions[index + 1].start : duration
                                let leading = min(0.25, max(0, (region.start - previous) / 2))
                                let trailing = min(0.25, max(0, (next - region.end) / 2))
                                return Int((region.start - leading) * 16000)..<min(samples.count, Int((region.end + trailing) * 16000))
                            }
                            let missing = SpeechCoverage.uncovered(speech: speech.map(sampleRange),
                                covered: covered, sampleCount: samples.count,
                                minimumPartialLength: 4800)
                            regions += missing.map { VoiceRegion(start: Double($0.lowerBound) / 16000,
                                end: Double($0.upperBound) / 16000, embedding: nil, recoveredSpeech: true) }
                            regions.sort { $0.start < $1.start }
                        }
                        regions = regions.flatMap { region -> [VoiceRegion] in
                            let lower = max(0, Int(region.start * 16000))
                            let upper = min(samples.count, Int(region.end * 16000))
                            guard upper > lower else { return [] }
                            return SpeechChunking.ranges(in: samples, range: lower..<upper).map {
                                VoiceRegion(start: Double($0.lowerBound) / 16000, end: Double($0.upperBound) / 16000,
                                    embedding: region.embedding, recoveredSpeech: region.recoveredSpeech)
                            }
                        }
                        for (index, region) in regions.enumerated() {
                            try Task.checkCancellation()
                            // Diarization timestamps can cut through a word. Restore a little
                            // surrounding sound without borrowing from a neighboring turn.
                            let previous = regions[..<index].filter { !$0.recoveredSpeech }.map(\.end).max() ?? 0
                            let next = regions.dropFirst(index + 1).first { !$0.recoveredSpeech }?.start ?? duration
                            // Microphone outer reads already reserve at most half
                            // the gap, so use all of that context at file edges.
                            let leadingDivisor = isMic && index == 0 ? 1.0 : 2.0
                            let trailingDivisor = isMic && index == regions.count - 1 ? 1.0 : 2.0
                            let leading = region.recoveredSpeech ? 0 : min(0.25, max(0, (region.start - previous) / leadingDivisor))
                            let trailing = region.recoveredSpeech ? 0 : min(0.25, max(0, (next - region.end) / trailingDivisor))
                            let lower = max(0, Int((region.start - leading) * 16000))
                            let upper = min(samples.count, Int((region.end + trailing) * 16000))
                            guard upper > lower else { continue }
                            let regionSamples = Array(samples[lower..<upper])
                            // A continuous VAD interval may bridge a brief pause.
                            // Confirm speech within the recovered gap itself so
                            // the language model never decodes a padded silence.
                            if region.recoveredSpeech, activity.regions(regionSamples).isEmpty { continue }
                            let expandedSamples: [Float]?
                            let overlap = max(0, previous - region.start) + max(0, region.end - next)
                            if region.end - region.start < 2, !region.recoveredSpeech, overlap <= 0.15 {
                                let bounds = max(0, Int(region.start * 16000))..<min(samples.count, Int(region.end * 16000))
                                let expansionPrevious = regions[..<index].map(\.end).max() ?? 0
                                let expansionNext = index + 1 < regions.count ? regions[index + 1].start : duration
                                let expanded = SpeechCoverage.safeExpansion(region: bounds, base: lower..<upper,
                                    previousEnd: max(0, Int(expansionPrevious * 16000)), nextStart: min(samples.count, Int(expansionNext * 16000)),
                                    sampleCount: samples.count, maximumPadding: 8000)
                                expandedSamples = expanded.map { Array(samples[$0]) }
                            } else { expandedSamples = nil }
                            let inferenceStarted = Date()
                            let recognized = try recognize(regionSamples, expandedSamples: expandedSamples, model: model,
                                russian: russian, vocabulary: context, duration: region.end - region.start)
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
        let localized = BackchannelLanguage.resolve(sorted, alternatives: backchannels,
            preceding: live ? recentLanguageSegments : [], vocabulary: context).map { segment in
                var revised = segment
                revised.text = TranscriptOrthography.normalize(segment.text, vocabulary: context)
                return revised
            }
        if live, let end = localized.map(\.end).max() {
            recentLanguageSegments = (recentLanguageSegments + localized).filter { $0.end >= end - 60 }
        }
        return live ? localized : SpeakerClustering.assign(localized, profiles: profiles)
    }

    private struct RecognizedSpeech { var text: String; var russianBackchannel: String? }

    private func recognize(_ samples: [Float], expandedSamples: [Float]?, model: Qwen3ASRModel, russian: RussianSpeechRecognizer?, vocabulary: String, duration: Double) throws -> RecognizedSpeech? {
        let audio = MLXArray(samples)
        let maxTokens = min(768, max(64, Int(duration * 16)))
        // On brief replies the vocabulary can be longer than the speech itself.
        let decodingVocabulary = spokenVocabulary.decodingVocabulary
        let context = duration >= 2 ? vocabulary : ""
        func generate(language: String?, context: String, audioSamples: [Float]? = nil, promptVocabulary: String? = nil) throws -> STTOutput {
            let input = audioSamples.map { MLXArray($0) } ?? audio
            return try RecognitionPromptEcho.decode(context: context, vocabulary: promptVocabulary ?? vocabulary, text: { $0.text }) { prompt in
                try Task.checkCancellation()
                return model.generate(audio: input, maxTokens: maxTokens, context: prompt,
                               language: language, chunkDuration: 30, repetitionPenalty: 1.1)
            }
        }
        let detected = try generate(language: nil, context: context)
        let language = detected.language?.lowercased()
        guard language != "none", !detected.text.isEmpty else { return nil }
        let allowed = language == "russian" || language == "english"
        let result: STTOutput
        if !allowed || MeetingSpeechText.containsForeignLetters(detected.text) {
            result = try generate(language: allowed ? detected.language : "Russian", context: "")
        } else {
            result = detected
        }
        var text = spokenVocabulary.apply(to: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
              !MeetingSpeechText.containsForeignLetters(text) else { return nil }
        try Task.checkCancellation()
        if BackchannelLanguage.shouldRecheck(text, duration: duration) {
            let decoded = try generate(language: "Russian", context: "")
            let alternative = BackchannelLanguage.alternative(original: text, russian: spokenVocabulary.apply(to: decoded.text),
                corroboration: russian?.recognize(samples), vocabulary: vocabulary)
            return RecognizedSpeech(text: text, russianBackchannel: alternative)
        }
        // Diarization can leave a complete lexical reply shorter than two
        // seconds, or clip its last syllable during an overlapping next turn.
        // Verify such replies with independent audio evidence, never a sentence
        // copied into the prompt. Expanded sound is accepted only on agreement.
        if result.language?.lowercased() == "russian", (0.35..<2).contains(duration),
           (2...6).contains(RussianRecognition.words(text).count), let russian,
           let independent = russian.recognize(samples),
           RussianRecognition.words(independent) != RussianRecognition.words(text) {
            let hints = spokenVocabulary.relevantTerms(in: [text, independent])
            if !hints.isEmpty {
                let checked = try generate(language: "Russian", context: hints, promptVocabulary: hints)
                let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let revised = RecognitionConsensus.revisedText(original: text, candidate: candidate,
                    corroboration: independent, vocabulary: vocabulary, allowShortTurn: true) {
                    return RecognizedSpeech(text: revised)
                }
            }
            if let expandedSamples, let independent = russian.recognize(expandedSamples) {
                let checked = try generate(language: "Russian", context: "", audioSamples: expandedSamples)
                let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let revised = RecognitionConsensus.revisedText(original: text, candidate: candidate,
                    corroboration: independent, vocabulary: vocabulary, allowShortTurn: true, expandedAudio: true) {
                    return RecognizedSpeech(text: revised)
                }
            }
        }
        if result.language?.lowercased() == "russian", duration >= 2,
           let rawHypothesis = russian?.recognize(samples) {
            let hypothesis = spokenVocabulary.promptHypothesis(rawHypothesis)
            let usesCyrillicHints = spokenVocabulary.hasCyrillicHints(in: rawHypothesis)
            if RussianRecognition.shouldRecheck(language: result.language, duration: duration, original: text, alternative: hypothesis) {
                try Task.checkCancellation()
                let checked = try generate(language: nil, context: RussianRecognition.context(vocabulary: context, hypothesis: hypothesis))
                let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if checked.language?.lowercased() == "russian",
                   let revised = RussianRecognition.revisedText(original: text, candidate: candidate,
                        corroboration: rawHypothesis, hypothesis: hypothesis, vocabulary: vocabulary,
                        usesCyrillicHints: usesCyrillicHints,
                        dictionaryCorroboration: spokenVocabulary.apply(to: rawHypothesis)) {
                    text = revised
                }
                // Different acoustic boundaries can make the broad hypothesis
                // distract from a name. Retry only a still-missing explicit
                // name heard by the verifier; keep successful repairs intact.
                if let focusedName = spokenVocabulary.focusedNameHypothesis(original: text, corroboration: rawHypothesis) {
                    try Task.checkCancellation()
                    let focused = try generate(language: nil, context: RussianRecognition.context(vocabulary: context, hypothesis: focusedName))
                    let candidate = spokenVocabulary.apply(to: focused.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if focused.language?.lowercased() == "russian",
                       let revised = RussianRecognition.revisedText(original: text, candidate: candidate,
                            corroboration: rawHypothesis, hypothesis: focusedName, vocabulary: vocabulary, usesCyrillicHints: false,
                            dictionaryCorroboration: spokenVocabulary.apply(to: rawHypothesis)),
                       spokenVocabulary.focusedNameHypothesis(original: revised, corroboration: rawHypothesis) == nil {
                        text = revised
                    }
                }
            }
        }
        // An intact letter stem and a spoken ending can survive even when a
        // fused numeral is misspelled. Use that spelling only as an audio hint;
        // accept the same form only at matching, unique neighboring words.
        if result.language?.lowercased() == "russian",
           let numericContext = spokenVocabulary.numericRepairContext(in: text) {
            let checked = try generate(language: "Russian", context: numericContext, promptVocabulary: numericContext)
            if let revised = spokenVocabulary.restoringNumericName(original: text, candidate: checked.text) {
                text = revised
            }
        }
        // A base-only glossary can bias an otherwise correct numeric name
        // towards losing its spoken case ending. Re-decode only an observed
        // numeric name with alternative spellings, then keep just the locally
        // anchored ending. Unrelated speech never receives these extra hints.
        if result.language?.lowercased() == "russian",
           spokenVocabulary.needsNumericEndingCheck(in: text) {
            let checked = try generate(language: "Russian", context: decodingVocabulary,
                promptVocabulary: decodingVocabulary)
            let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let revised = RussianRecognition.restoringNumericEndings(original: text, candidate: candidate, vocabulary: vocabulary) {
                text = revised
            }
        }
        return RecognizedSpeech(text: text)
    }
}
