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
    private var activeShortDecodes = 0
    private var vocabularySource: String?
    private var spokenVocabulary = SpokenVocabulary("")
    private var contextDiagnostics: [[String: String]] = []
    func recognitionContextDiagnostics() -> [[String: String]] { contextDiagnostics }

    /// Used by the local synthetic integration fixture to check session reuse.
    func liveModelIdentity() -> ObjectIdentifier? { liveModel.map(ObjectIdentifier.init) }
    func liveRussianModelIdentity() -> ObjectIdentifier? { liveRussian.map(ObjectIdentifier.init) }
    func shortDecodeIsActive() -> Bool { activeShortDecodes > 0 }

    private func decodeShortMicrophone(_ model: Qwen3ASRModel, audio: MLXArray, maxTokens: Int) async throws -> STTOutput {
        try Task.checkCancellation()
        activeShortDecodes += 1
        defer { activeShortDecodes -= 1 }
        // The short streaming API preserves a missing language as nil, rather
        // than substituting English. Drain it in an independent collector:
        // cancellation must not release MLX state while its producer still runs.
        let collector = Task<STTOutput, Error> {
            var final: STTOutput?
            for try await update in model.generateStream(audio: audio, maxTokens: maxTokens, context: "", language: nil, chunkDuration: 24, repetitionPenalty: 1.1) {
                if case .result(let result) = update { final = result }
            }
            guard let final else { throw PisyaError.message("Распознавание не вернуло результат") }
            return final
        }
        let result = try await collector.value
        try Task.checkCancellation()
        return result
    }

    func finishLive() {
        liveModel = nil; liveActivity = nil; liveVoices = nil; liveRussian = nil
        recentLanguageSegments = []
        Memory.clearCache()
        if let limit = previousLiveCacheLimit { Memory.cacheLimit = limit; previousLiveCacheLimit = nil }
    }

    func transcribe(files: [(URL, Double)], modelDirectory: URL, context: String, speakerDirectory: URL, profiles: [VoiceProfile], quiet: Bool = true, live: Bool = false, russianVerification: Bool = true, contextualVerification: Bool = true, preceding: [TranscriptSegment] = [], collectDiagnostics: Bool = false, progress: @escaping @Sendable (Double, String) async -> Void) async throws -> [TranscriptSegment] {
        contextDiagnostics = []
        guard FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path), FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("model.safetensors").path) else { throw PisyaError.message("Выберите папку модели Qwen3-ASR с config.json и model.safetensors") }
        let previousCacheLimit = Memory.cacheLimit
        if live && previousLiveCacheLimit == nil { previousLiveCacheLimit = previousCacheLimit }
        Memory.cacheLimit = 256 * 1024 * 1024
        defer { if !live { Memory.clearCache(); Memory.cacheLimit = previousCacheLimit } }
        prepareVocabulary(context)
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
        var acousticHypotheses: [UUID: RecognitionAcousticResult] = [:]
        var audioBounds: [UUID: Range<Double>] = [:]
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
                            let recognized = try await recognize(regionSamples, expandedSamples: expandedSamples, model: model,
                                russian: russian, vocabulary: context, duration: region.end - region.start, isMic: isMic)
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
                            acousticHypotheses[segment.id] = recognized.acoustic
                            audioBounds[segment.id] = (start + Double(lower) / 16000)..<(start + Double(upper) / 16000)
                            segments.append(segment)

                        }
                    }
                }
                position += AVAudioFramePosition(input.frameLength)
                let fraction = (Double(fileIndex) + Double(position) / Double(max(1, total))) / Double(preparedFiles.count)
                await progress(0.12 + fraction * (contextualVerification ? 0.73 : 0.88), "Распознаю · \(timecode(start + duration))")
            }
        }
        var sorted = segments.sorted { $0.start < $1.start }
        if contextualVerification {
            sorted = try await contextualRevision(sorted, preceding: preceding,
                files: preparedFiles, bounds: audioBounds, hypotheses: acousticHypotheses, model: model, russian: russian,
                vocabulary: context,
                quiet: quiet, collectDiagnostics: collectDiagnostics, progress: progress)
        }
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
        try Task.checkCancellation()
        keepGenerated = generated.map { url in localized.contains { $0.audioFile == url.lastPathComponent } } ?? false
        return live ? localized : SpeakerClustering.assign(localized, profiles: profiles)
    }

    private func prepareVocabulary(_ vocabulary: String) {
        guard vocabularySource != vocabulary else { return }
        let pronunciations = Bundle.main.url(forResource: "cmudict", withExtension: "dict")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        spokenVocabulary = SpokenVocabulary(vocabulary, pronunciations: pronunciations)
        vocabularySource = vocabulary
    }

    /// Replay selected turns against a frozen meeting transcript and existing
    /// audio. Caller can supply the exact padded file-local decode intervals.
    func replayRecognitionContext(_ frozen: [TranscriptSegment], files: [(URL, Double)],
        modelDirectory: URL, speakerDirectory: URL, vocabulary: String, selected: Set<UUID>,
        suppliedBounds: [UUID: Range<Double>], repeatFirstPass: Bool) async throws -> [TranscriptSegment] {
        contextDiagnostics = []
        prepareVocabulary(vocabulary)
        let priorLimit = Memory.cacheLimit
        Memory.cacheLimit = 256 * 1024 * 1024
        defer { Memory.clearCache(); Memory.cacheLimit = priorLimit }
        let model = try await Qwen3ASRModel.fromModelDirectory(modelDirectory)
        let russian = try RussianSpeechRecognizer(directory: speakerDirectory.deletingLastPathComponent()
            .appendingPathComponent(RussianSpeechRecognizer.directoryName))
        var segments = frozen.sorted { $0.start < $1.start }
        var bounds = suppliedBounds
        var hypotheses: [UUID: RecognitionAcousticResult] = [:]
        for (url, offset) in files {
            let name = url.lastPathComponent
            let track = segments.indices.filter { segments[$0].audioFile == name }
            for (position, index) in track.enumerated() {
                let segment = segments[index]
                let priorEnd = position > 0 ? segments[track[position - 1]].end : segment.start - 0.5
                let nextStart = position + 1 < track.count ? segments[track[position + 1]].start : segment.end + 0.5
                let start = max(0, segment.start - offset - min(0.25, max(0, (segment.start - priorEnd) / 2)))
                let end = max(start, segment.end - offset + min(0.25, max(0, (nextStart - segment.end) / 2)))
                let interval = suppliedBounds[segment.id] ?? start..<end
                bounds[segment.id] = interval
                guard selected.contains(segment.id) else { continue }
                let samples = try Self.contextSamples(url, start: interval.lowerBound, end: interval.upperBound)
                if repeatFirstPass,
                   let recognized = try recognize(samples, expandedSamples: nil, model: model, russian: russian,
                                                  vocabulary: vocabulary, duration: segment.end - segment.start) {
                    segments[index].text = recognized.text
                    hypotheses[segment.id] = recognized.acoustic
                } else {
                    hypotheses[segment.id] = russian.recognizeDetailed(samples)
                }
            }
        }
        return try await contextualRevision(segments, preceding: [], files: files, bounds: bounds,
            hypotheses: hypotheses, model: model, russian: russian, vocabulary: vocabulary,
            quiet: false, collectDiagnostics: true, selected: selected) { _, _ in }
    }

    private struct RecognizedSpeech { var text: String; var russianBackchannel: String?; var acoustic: RecognitionAcousticResult? }

    /// Use a frozen, chronological first pass from both tracks. A proposed
    /// correction never becomes evidence for a later correction in this pass.
    private func contextualRevision(_ segments: [TranscriptSegment], preceding: [TranscriptSegment],
        files: [(URL, Double)], bounds: [UUID: Range<Double>], hypotheses: [UUID: RecognitionAcousticResult], model: Qwen3ASRModel,
        russian: RussianSpeechRecognizer?, vocabulary: String, quiet: Bool, collectDiagnostics: Bool,
        selected: Set<UUID>? = nil, progress: @escaping @Sendable (Double, String) async -> Void) async throws -> [TranscriptSegment] {
        guard let russian, !vocabulary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            try Task.checkCancellation()
            await progress(1, "Расшифровка готова")
            return segments
        }
        let snapshot = RecognitionContext(segments: segments, preceding: preceding)
        var revised = segments
        for (index, segment) in segments.enumerated() {
            try Task.checkCancellation()
            if let selected, !selected.contains(segment.id) { continue }
            if collectDiagnostics {
                contextDiagnostics.append(["start": String(segment.start), "track": segment.audioFile ?? "",
                    "source": segment.text, "independent": hypotheses[segment.id]?.text ?? "", "kind": "first-pass"])
            }
            guard let name = segment.audioFile, let (url, offset) = files.first(where: { $0.0.lastPathComponent == name }),
                  let audioRange = bounds[segment.id] else { continue }
            let duration = segment.end - segment.start
            if duration < 2 {
                guard RecognitionContext.isWordRichShortTurn(segment.text, duration: duration),
                      let samples = try? Self.contextSamples(url, start: audioRange.lowerBound, end: audioRange.upperBound),
                      let heard = hypotheses[segment.id]?.text ?? russian.recognize(samples),
                      (4...6).contains(RussianRecognition.words(heard).count),
                      RussianRecognition.words(heard) != RussianRecognition.words(segment.text) else { continue }
                let hints = spokenVocabulary.relevantTerms(in: [segment.text, heard])
                let audio = MLXArray(samples)
                for prompt in (hints.isEmpty ? [""] : [hints, ""]) {
                    try Task.checkCancellation()
                    let output = RecognitionPromptEcho.decode(context: prompt, vocabulary: prompt, text: { $0.text }) {
                        model.generate(audio: audio, maxTokens: 96, context: $0, language: "Russian",
                                       chunkDuration: 30, repetitionPenalty: 1.1)
                    }
                    let candidate = spokenVocabulary.apply(to: output.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if collectDiagnostics {
                        contextDiagnostics.append(["start": String(segment.start), "kind": "short-turn",
                            "source": segment.text, "independent": heard, "candidate": candidate])
                    }
                    if let accepted = RecognitionContext.wordRichShortTurn(original: segment.text, candidate: candidate,
                            corroboration: heard, duration: duration, vocabulary: vocabulary) {
                        revised[index].text = accepted
                        if collectDiagnostics {
                            contextDiagnostics.append(["start": String(segment.start), "kind": "accepted",
                                "source": segment.text, "candidate": accepted])
                        }
                        break
                    }
                }
                continue
            }
            guard duration <= 30 else { continue }
            let independent = hypotheses[segment.id]?.text
            let retry = snapshot.plan(for: segment, independent: independent,
                                      vocabulary: vocabulary, spokenVocabulary: spokenVocabulary)
            let tailDiffers = independent.map {
                RussianRecognition.words($0).suffix(3) != RussianRecognition.words(segment.text).suffix(3)
            } ?? false
            let continuation = (retry != nil || (segment.end - segment.start >= 12 && tailDiffers))
                ? snapshot.continuation(after: segment) : nil
            guard retry != nil || continuation != nil else {
                if collectDiagnostics { contextDiagnostics.append(["start": String(segment.start), "kind": "no-plan"]) }
                continue
            }
            // Reuse the first pass's padded interval. A failed optional reread preserves that pass.
            guard let samples = try? Self.contextSamples(url, start: audioRange.lowerBound, end: audioRange.upperBound),
                  !samples.isEmpty else { continue }
            let acoustic = hypotheses[segment.id] ?? russian.recognizeDetailed(samples)
            let began = Date()
            func decode(_ prompt: String, samples: [Float], retry: RecognitionContext.Retry,
                        applyVocabulary: Bool = true) throws -> String {
                let audio = MLXArray(samples)
                func generate(_ context: String) throws -> STTOutput {
                    try Task.checkCancellation()
                    return model.generate(audio: audio, maxTokens: min(768, max(96, Int(Double(samples.count) / 16000 * 20))),
                        context: context, language: "Russian", chunkDuration: 30, repetitionPenalty: 1.1)
                }
                let result = try RecognitionPromptEcho.decode(context: prompt, vocabulary: retry.hints,
                    text: { $0.text }, generate: generate)
                // Neighboring speech is also a prompt, never a substitute for
                // this region's audio. Recover by decoding without it once.
                let text = !prompt.isEmpty && retry.isNeighborEcho(result.text) ? try generate("").text : result.text
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return applyVocabulary ? spokenVocabulary.apply(to: trimmed) : trimmed
            }
            var lastCandidate = ""
            func consider(_ samples: [Float], evidence: RecognitionAcousticResult?, source: String,
                          retry: RecognitionContext.Retry, prompt: String, kind: String) throws -> String? {
                let candidate = try decode(prompt, samples: samples, retry: retry)
                lastCandidate = candidate
                if collectDiagnostics {
                    contextDiagnostics.append(["start": String(segment.start), "track": name, "source": source,
                        "independent": evidence?.text ?? "", "hints": retry.hints, "kind": kind, "candidate": candidate])
                }
                let raw = evidence?.text
                let revised = RecognitionContext.revisedText(original: source, candidate: candidate,
                    corroboration: raw, retry: retry, vocabulary: vocabulary)
                if let revised { return revised }
                guard let raw else { return nil }
                let canonical = spokenVocabulary.apply(to: raw)
                return canonical == raw ? nil : RecognitionContext.revisedText(original: source, candidate: candidate,
                    corroboration: canonical, retry: retry, vocabulary: vocabulary)
            }
            func focused(_ samples: [Float], evidence: RecognitionAcousticResult?, retry: RecognitionContext.Retry,
                         kind: String) throws -> String? {
                guard let evidence else { return nil }
                let targets = retry.targetSpans(in: segment.text, corroboration: spokenVocabulary.apply(to: evidence.text))
                let ranges = RecognitionAudioFocus.ranges(original: segment.text,
                    targets: targets,
                    words: evidence.words, duration: Double(samples.count) / 16000)
                if collectDiagnostics {
                    contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-windows",
                        "timedWords": String(evidence.words.count), "targets": targets.map { String(segment.text[$0]) }.joined(separator: " | "),
                        "ranges": ranges.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: ", ")])
                }
                for range in ranges.prefix(2) {
                    try Task.checkCancellation()
                    let lower = max(0, min(samples.count, Int(range.lowerBound * 16000)))
                    let upper = max(lower, min(samples.count, Int(range.upperBound * 16000)))
                    guard upper > lower else { continue }
                    let clip = Array(samples[lower..<upper])
                    let heard = russian.recognizeDetailed(clip)
                    if let heard, let joined = RecognitionContext.reconcileObservedInitialismBoundary(
                        original: segment.text, independent: heard.text, retry: retry, vocabulary: vocabulary) {
                        if collectDiagnostics {
                            contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-boundary",
                                "source": segment.text, "independent": heard.text, "candidate": joined])
                        }
                        return joined
                    }
                    if let revised = try consider(clip, evidence: heard, source: segment.text, retry: retry, prompt: retry.hints, kind: kind) { return revised }
                    let checkEnding = retry.canDisambiguateInitialismEnding(in: segment.text)
                    let checkBoundary = retry.canProbePhoneticBoundary(in: segment.text, corroboration: evidence.text)
                    if checkEnding {
                        let candidate = lastCandidate
                        var unprompted: [String] = []
                        var expandedProbe: [Float]?
                        for margin in [0.0, 1.25] {
                            let a = max(0, Int((range.lowerBound - margin) * 16000))
                            let b = min(samples.count, Int((range.upperBound + margin) * 16000))
                            if margin > 0, a == lower, b == upper { continue }
                            let probeSamples = Array(samples[a..<b])
                            if margin > 0 { expandedProbe = probeSamples }
                            let probe = try decode("", samples: probeSamples, retry: retry, applyVocabulary: false)
                            unprompted.append(probe)
                            if collectDiagnostics {
                                contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-unprompted",
                                    "margin": String(margin), "candidate": probe, "source": segment.text])
                            }
                        }
                        if checkEnding, unprompted.count == 2 {
                            var disambiguated = RecognitionContext.disambiguateInitialismEnding(
                                original: segment.text, candidate: candidate, unprompted: unprompted,
                                retry: retry, vocabulary: vocabulary)
                            if disambiguated == nil, let expandedProbe {
                                let expandedCandidate = try decode(retry.hints, samples: expandedProbe, retry: retry)
                                if collectDiagnostics {
                                    contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-expanded",
                                        "source": segment.text, "candidate": expandedCandidate])
                                }
                                disambiguated = RecognitionContext.disambiguateInitialismEnding(
                                    original: segment.text, candidate: expandedCandidate, unprompted: unprompted,
                                    retry: retry, vocabulary: vocabulary)
                            }
                            if let disambiguated {
                                if collectDiagnostics {
                                    contextDiagnostics.append(["start": String(segment.start), "kind": "contextual-spelling",
                                        "source": segment.text, "candidate": disambiguated])
                                }
                                return disambiguated
                            }
                        }
                    }
                    if checkBoundary, let heard {
                        let a = max(0, lower - 4_800), b = min(samples.count, upper + 4_800)
                        if a > 0 || b < samples.count {
                            let wide = try decode("", samples: samples, retry: retry, applyVocabulary: false)
                            let narrow = try decode("", samples: Array(samples[a..<b]), retry: retry, applyVocabulary: false)
                            if collectDiagnostics {
                                contextDiagnostics.append(["start": String(segment.start), "kind": "phonetic-boundary-unprompted",
                                    "source": segment.text, "independent": heard.text, "candidate": wide, "narrow": narrow])
                            }
                            let observed = RecognitionContext.reconcileObservedInitialismBoundary(original: wide,
                                independent: heard.text, retry: retry, vocabulary: vocabulary) ?? wide
                            if let boundary = RecognitionContext.revisedText(original: segment.text, candidate: observed,
                                corroboration: heard.text, retry: retry, vocabulary: vocabulary, boundaryEvidence: [observed, narrow])
                                ?? RecognitionContext.reconcilePhoneticBoundary(original: segment.text, corroboration: heard.text,
                                    unprompted: [wide, narrow], retry: retry, vocabulary: vocabulary) {
                                return boundary
                            }
                        }
                    }
                    if let heard, !heard.text.isEmpty {
                        let prompt = RussianRecognition.context(vocabulary: retry.hints,
                            hypothesis: spokenVocabulary.promptHypothesis(heard.text))
                        if let revised = try consider(clip, evidence: heard, source: segment.text, retry: retry, prompt: prompt, kind: kind + "-acoustic") { return revised }
                    }
                }
                return nil
            }
            var accepted: String?
            if let retry {
                accepted = try consider(samples, evidence: acoustic, source: segment.text, retry: retry,
                                        prompt: retry.hints, kind: "hints")
                if accepted == nil { accepted = try focused(samples, evidence: acoustic, retry: retry, kind: "focus") }
                if accepted == nil, retry.context != retry.hints {
                    accepted = try consider(samples, evidence: acoustic, source: segment.text, retry: retry,
                                            prompt: retry.context, kind: "neighbors")
                }
            }
            if accepted == nil, let continuation {
                let end = min(continuation.segment.end - offset, continuation.segment.start - offset + 3.5)
                if end > audioRange.upperBound + 0.2,
                   let expanded = try? Self.contextSamples(url, start: audioRange.lowerBound, end: end),
                   let heard = russian.recognizeDetailed(expanded) {
                    var joined = segment
                    joined.text += continuation.suffix
                    if let boundaryRetry = snapshot.plan(for: joined, independent: heard.text,
                                                         vocabulary: vocabulary, spokenVocabulary: spokenVocabulary) {
                        let replacement = try consider(expanded, evidence: heard, source: joined.text, retry: boundaryRetry,
                                                       prompt: boundaryRetry.hints, kind: "right-anchor")
                        accepted = replacement.flatMap(continuation.splice)
                            ?? RecognitionContext.revisedAcrossBoundary(original: segment.text, candidate: lastCandidate,
                                corroboration: heard.text, continuation: continuation, retry: boundaryRetry, vocabulary: vocabulary)
                    }
                }
            }
            if let accepted {
                revised[index].text = accepted
                if collectDiagnostics { contextDiagnostics.append(["start": String(segment.start), "kind": "accepted", "source": segment.text, "candidate": accepted]) }
            }
            await progress(0.85 + 0.15 * Double(index + 1) / Double(max(1, segments.count)),
                "Уточняю по контексту · \(timecode(segment.start))")
            let thermal = ProcessInfo.processInfo.thermalState
            if quiet || thermal == .serious || thermal == .critical {
                let delay = min(3, max(0.1, Date().timeIntervalSince(began) * (quiet ? 0.6 : 0.2)))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        try Task.checkCancellation()
        await progress(1, "Расшифровка готова")
        return revised
    }

    private static func contextSamples(_ url: URL, start: Double, end: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let lower = max(0, min(file.length, AVAudioFramePosition(start * rate)))
        let upper = max(lower, min(file.length, AVAudioFramePosition(end * rate)))
        guard upper > lower else { return [] }
        file.framePosition = lower
        let input = try PCMRead.exact(file, frames: AVAudioFrameCount(upper - lower))
        let target = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) / rate * 16000) + 64)) else {
            throw PisyaError.message("Не удалось прочитать аудио для уточнения расшифровки")
        }
        var delivered = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .endOfStream; return nil }
            delivered = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    private func recognize(_ samples: [Float], expandedSamples: [Float]?, model: Qwen3ASRModel, russian: RussianSpeechRecognizer?, vocabulary: String, duration: Double, isMic: Bool) async throws -> RecognizedSpeech? {
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
        let shortMic = isMic && duration <= 1.5
        let detected: STTOutput
        if shortMic {
            detected = try await decodeShortMicrophone(model, audio: audio, maxTokens: maxTokens)
        } else {
            detected = try generate(language: nil, context: context)
        }
        let language = detected.language?.lowercased()
        guard language != "none", !detected.text.isEmpty else { return nil }
        let allowed = language == "russian" || language == "english"
        let result: STTOutput
        let retryLanguage = shortMic
            ? !allowed && MicrophoneLanguage.shouldRetryRussian(duration: duration, language: detected.language,
                languageIsExplicit: detected.language != nil, text: detected.text, supportedLanguages: model.config.supportLanguages)
            : !allowed
        if retryLanguage || MeetingSpeechText.containsForeignLetters(detected.text) {
            result = try generate(language: allowed ? detected.language : "Russian", context: "")
        } else {
            result = detected
        }
        var text = spokenVocabulary.apply(to: result.text.trimmingCharacters(in: .whitespacesAndNewlines))
        var acoustic: RecognitionAcousticResult?
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
           let rawResult = russian?.recognizeDetailed(samples) {
            let rawHypothesis = rawResult.text
            acoustic = rawResult
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
        return RecognizedSpeech(text: text, acoustic: acoustic)
    }
}
