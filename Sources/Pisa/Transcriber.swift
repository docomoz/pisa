import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

/// All inference stays on one actor. A model is released after each meeting.
actor Transcriber {
    enum WindowBoundaryCheck: Sendable {
        case lookahead(LiveTranscriptionSchedule.Window)
        case nominal(LiveTranscriptionSchedule.Window, isMic: Bool)
    }

    struct WindowPass: Sendable {
        enum Retry: Sendable {
            case withoutLookahead(isMic: Bool)
            case withLookahead
        }
        var segments: [TranscriptSegment] = []
        var retry: Retry?
    }

    private var liveModel: ParakeetRecognitionSession?
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

    private var performanceDiagnostics: [String: Double]?
    func resetRecognitionPerformanceDiagnostics() {
        performanceDiagnostics = Dictionary(uniqueKeysWithValues:
            ["parakeet", "qwen", "giga", "parakeetLoad", "qwenLoad", "speakerLoad", "gigaLoad", "diarization"].flatMap { [$0 + "Calls", $0 + "Seconds"] }
                .map { ($0, 0.0) })
        performanceDiagnostics?["qwenLoadFailures"] = 0
        for phase in ["firstPassTotal", "recognizeTotal", "contextTotal", "finalizationTotal"] {
            for metric in ["Calls", "Seconds", "UnaccountedSeconds"] { performanceDiagnostics?[phase + metric] = 0 }
        }
    }
    func recognitionPerformanceDiagnostics() -> [String: Double] { performanceDiagnostics ?? [:] }

    private func measureRecognition<T>(_ kind: String, _ body: () throws -> T) rethrows -> T {
        guard performanceDiagnostics != nil else { return try body() }
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            performanceDiagnostics?[kind + "Calls", default: 0] += 1
            performanceDiagnostics?[kind + "Seconds", default: 0] += ProcessInfo.processInfo.systemUptime - began
        }
        return try body()
    }

    private struct PerformanceInterval {
        let began: TimeInterval
        let accounted: TimeInterval
    }

    private func accountedRecognitionSeconds() -> TimeInterval {
        ["parakeet", "qwen", "giga", "parakeetLoad", "qwenLoad", "speakerLoad", "gigaLoad", "diarization"]
            .reduce(SpeakerEmbeddingExtractor.inferenceMetrics.inferenceSeconds) {
                $0 + (performanceDiagnostics?[$1 + "Seconds"] ?? 0)
            }
    }

    private func beginPerformanceInterval() -> PerformanceInterval? {
        guard performanceDiagnostics != nil else { return nil }
        return PerformanceInterval(began: ProcessInfo.processInfo.systemUptime, accounted: accountedRecognitionSeconds())
    }

    private func endPerformanceInterval(_ interval: PerformanceInterval?, kind: String) {
        guard let interval else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - interval.began
        let accounted = accountedRecognitionSeconds() - interval.accounted
        performanceDiagnostics?[kind + "Calls", default: 0] += 1
        performanceDiagnostics?[kind + "Seconds", default: 0] += elapsed
        // Enclosing buckets overlap intentionally. Subtract only leaf inference,
        // load and embedding timers, never another enclosing phase's duration.
        performanceDiagnostics?[kind + "UnaccountedSeconds", default: 0] += max(0, elapsed - accounted)
    }

    private func acousticRecognition(_ samples: [Float], using russian: RussianSpeechRecognizer?) -> RecognitionAcousticResult? {
        guard let russian else { return nil }
        return measureRecognition("giga") { russian.recognizeDetailed(samples) }
    }

    private func verificationModel(_ session: ParakeetRecognitionSession) async throws -> Qwen3ASRModel {
        let beforeCount = session.verifierLoadCount, beforeSeconds = session.verifierLoadSeconds
        let beforeFailures = session.verifierLoadFailures
        defer {
            performanceDiagnostics?["qwenLoadCalls", default: 0] += Double(session.verifierLoadCount - beforeCount)
            performanceDiagnostics?["qwenLoadSeconds", default: 0] += session.verifierLoadSeconds - beforeSeconds
            performanceDiagnostics?["qwenLoadFailures", default: 0] += Double(session.verifierLoadFailures - beforeFailures)
        }
        return try await session.verifier()
    }

    private func verify(_ samples: [Float], with verifier: Qwen3ASRModel, session: ParakeetRecognitionSession,
                        maxTokens: Int, context: String, language: String?) -> STTOutput {
        let cache = session.verificationCache
        let previousHits = cache.hitCount
        let result = cache.value(samples: samples, context: context, language: language, maxTokens: maxTokens,
            prepare: { Qwen3ASRReusableAudio(MLXArray(samples)) }, generate: { clip in
                let previousReuses = clip.reuseCount
                defer {
                    performanceDiagnostics?["qwenEncoderReuses", default: 0] += Double(clip.reuseCount - previousReuses)
                }
                return measureRecognition("qwen") {
                    verifier.generate(reusing: clip, maxTokens: maxTokens, context: context, language: language,
                                      chunkDuration: 30, repetitionPenalty: 1.1)
                }
            }, completedTokens: { $0.segments?.count == 1 ? $0.generationTokens : nil })
        performanceDiagnostics?["qwenCacheHits", default: 0] += Double(cache.hitCount - previousHits)
        return result
    }

    /// Used by the local synthetic integration fixture to check session reuse.
    func liveModelIdentity() -> ObjectIdentifier? { liveModel.map { ObjectIdentifier($0.primary) } }
    func liveRussianModelIdentity() -> ObjectIdentifier? { liveRussian.map(ObjectIdentifier.init) }
    func shortDecodeIsActive() -> Bool { activeShortDecodes > 0 }

    private func decodeShortMicrophone(_ model: ParakeetModel, audio: MLXArray) async throws -> STTOutput {
        try Task.checkCancellation()
        activeShortDecodes += 1
        let began = ProcessInfo.processInfo.systemUptime
        defer {
            activeShortDecodes -= 1
            performanceDiagnostics?["parakeetCalls", default: 0] += 1
            performanceDiagnostics?["parakeetSeconds", default: 0] += ProcessInfo.processInfo.systemUptime - began
        }
        // The short streaming API preserves a missing language as nil, rather
        // than substituting English. Drain it in an independent collector:
        // cancellation must not release MLX state while its producer still runs.
        let collector = Task<STTOutput, Error> {
            var final: STTOutput?
            for try await update in model.generateStream(audio: audio, generationParameters: ParakeetRecognitionSession.primaryParameters) {
                if case .result(let result) = update { final = result }
            }
            guard let final else { throw PisaError.message("Распознавание не вернуло результат") }
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

    func transcribe(files: [(URL, Double)], modelDirectory: URL, context: String,
                    speakerDirectory: URL, verifierDirectory: URL? = nil, profiles: [VoiceProfile]? = nil, quiet: Bool = true,
                    performance: TranscriptionPerformance? = nil, live: Bool = false, russianVerification: Bool = true,
                    contextualVerification: Bool = true, preceding: [TranscriptSegment] = [], collectDiagnostics: Bool = false,
                    retainProcessedMicrophone: Bool = true, checkpointURL: URL? = nil,
                    progress: @escaping @Sendable (Double, String) async -> Void) async throws -> [TranscriptSegment] {
        try await transcribeAudio(files: files, modelDirectory: modelDirectory, context: context, speakerDirectory: speakerDirectory, verifierDirectory: verifierDirectory,
            profiles: profiles, performance: performance ?? TranscriptionPerformance(mode: quiet ? .quiet : .normal), live: live,
            russianVerification: russianVerification, contextualVerification: contextualVerification, preceding: preceding,
            collectDiagnostics: collectDiagnostics, retainProcessedMicrophone: retainProcessedMicrophone, checkpointURL: checkpointURL, progress: progress).segments
    }

    func transcribeWindow(files: [(URL, Double)], echoHistory: [CaptureWindowFile] = [],
                          modelDirectory: URL, context: String, speakerDirectory: URL, verifierDirectory: URL? = nil,
                          performance: TranscriptionPerformance, preceding: [TranscriptSegment],
                          boundaryCheck: WindowBoundaryCheck?) async throws -> WindowPass {
        try await transcribeAudio(files: files, modelDirectory: modelDirectory, context: context, speakerDirectory: speakerDirectory, verifierDirectory: verifierDirectory,
            performance: performance, live: true, preceding: preceding, echoHistory: echoHistory, boundaryCheck: boundaryCheck) { _, _ in }
    }

    private func transcribeAudio(files: [(URL, Double)], modelDirectory: URL, context: String, speakerDirectory: URL, verifierDirectory: URL? = nil,
                                 profiles: [VoiceProfile]? = nil, performance: TranscriptionPerformance, live: Bool,
                                 russianVerification: Bool = true, contextualVerification: Bool = true,
                                 preceding: [TranscriptSegment], collectDiagnostics: Bool = false, echoHistory: [CaptureWindowFile] = [],
                                 boundaryCheck: WindowBoundaryCheck? = nil, retainProcessedMicrophone: Bool = false, checkpointURL: URL? = nil,
                                 progress: @escaping @Sendable (Double, String) async -> Void) async throws -> WindowPass {
        contextDiagnostics = []
        guard SpeechModelFiles.isUsable(at: modelDirectory, kind: .parakeet) else { throw PisaError.message("Выберите папку модели Parakeet с config.json и model.safetensors") }
        let verifierDirectory = ParakeetRecognitionPolicy.verifierDirectory(explicit: verifierDirectory, speakerDirectory: speakerDirectory)
        // Checkpoint stamps also need custom-folder access before the lazy model
        // session is created. Its own grant survives across live windows.
        let verifierAccess = verifierDirectory.startAccessingSecurityScopedResource()
        defer { if verifierAccess { verifierDirectory.stopAccessingSecurityScopedResource() } }
        let previousCacheLimit = Memory.cacheLimit
        if live && previousLiveCacheLimit == nil { previousLiveCacheLimit = previousCacheLimit }
        Memory.cacheLimit = 256 * 1024 * 1024
        defer { if !live { Memory.clearCache(); Memory.cacheLimit = previousCacheLimit } }
        let checkpoint: BatchTranscriptionCheckpoint?
        if let checkpointURL {
            let russianDirectory = speakerDirectory.deletingLastPathComponent()
                .appendingPathComponent(RussianSpeechRecognizer.directoryName)
            let russianFiles = ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]
                .map { russianDirectory.appendingPathComponent($0) }
            let speakerFiles = ["titanet.onnx", "segmentation.onnx"].map { speakerDirectory.appendingPathComponent($0) }
            let bundledModels = [Bundle.main.url(forResource: "silero_vad", withExtension: "onnx")].compactMap { $0 }
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
            let inputs = try BatchTranscriptionCheckpoint.Inputs(files: files, model: modelDirectory,
                vocabulary: context, variants: ParakeetRecognitionPolicy.checkpointVariants, build: build,
                supportingModels: speakerFiles + russianFiles + bundledModels + ParakeetRecognitionPolicy.verifierCheckpointFiles(directory: verifierDirectory, speakerDirectory: speakerDirectory))
            let saved = try await ProtectedFileRead.waitForAccess(read: {
                try BatchTranscriptionCheckpoint.load(from: checkpointURL)
            }, onDenied: {})
            if let saved, !Set(saved.inputs.tracks.map(\.name)).isSubset(of: Set(inputs.tracks.map(\.name))) {
                throw PisaError.message("Одна из аудиодорожек встречи недоступна")
            }
            if let saved, saved.inputs == inputs { checkpoint = saved }
            else {
                checkpoint = BatchTranscriptionCheckpoint(inputs: inputs)
                try await ProtectedFileRead.waitForAccess(read: {
                    try checkpoint?.save(to: checkpointURL)
                }, onDenied: {})
            }
        } else { checkpoint = nil }
        let firstPass = checkpoint?.recognition ?? BatchTranscriptionCheckpoint.FirstPass()
        var committedSegmentCount = firstPass.segments.count
        defer {
            if Task.isCancelled, let checkpoint, let checkpointURL {
                checkpoint.trimUncommittedSegments(after: committedSegmentCount)
                try? checkpoint.save(to: checkpointURL)
            }
        }
        let resumeProgress = min(checkpoint?.progress ?? 0, 0.99)
        // A restarted process still needs its models and any transient audio preparation.
        // Keep the saved fraction visible during that work.
        let report: @Sendable (Double, String) async -> Void = { fraction, description in
            await progress(max(resumeProgress, fraction), description)
        }
        prepareVocabulary(context)
        var generated: URL?
        var sourceMicrophone: URL?
        var scratch: URL?
        var keepGenerated = false
        defer {
            if let scratch { try? FileManager.default.removeItem(at: scratch) }
            else if !keepGenerated, let generated { try? FileManager.default.removeItem(at: generated) }
        }
        var preparedFiles = files.filter { !$0.0.lastPathComponent.contains(".clean.") }
        if let mic = preparedFiles.first(where: { $0.0.lastPathComponent.contains("-mic.") }),
           let remote = preparedFiles.first(where: { $0.0.lastPathComponent.contains("-remote.") }) {
            await report(0, "Подготавливаю подавление эха")
            if !retainProcessedMicrophone || checkpointURL != nil {
                let directory = checkpointURL?.appendingPathExtension("audio")
                    ?? FileManager.default.temporaryDirectory.appendingPathComponent("pisa-transcription-" + UUID().uuidString)
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                scratch = directory
            }
            let micHistory = echoHistory.first { $0.url.lastPathComponent.contains("-mic.") }
            let remoteHistory = echoHistory.first { $0.url.lastPathComponent.contains("-remote.") }
            let micOffset = micHistory?.offset ?? mic.1
            let clean = try await AcousticEcho.clean(microphone: micHistory?.url ?? mic.0, offset: micOffset,
                reference: remoteHistory?.url ?? remote.0, referenceOffset: remoteHistory?.offset ?? remote.1,
                outputStart: mic.1, outputDirectory: scratch) { fraction, phase in
                await report(fraction * 0.12, phase)
            }
            generated = clean
            if let previous = checkpoint?.processedMicrophone {
                for index in firstPass.segments.indices where firstPass.segments[index].audioFile == previous {
                    firstPass.segments[index].audioFile = clean.lastPathComponent
                }
            }
            checkpoint?.processedMicrophone = clean.lastPathComponent
            sourceMicrophone = mic.0
            let cleanOffset = micOffset + Double(AcousticEcho.outputStartFrame(offset: micOffset, start: mic.1)) / 16_000
            preparedFiles = preparedFiles.map { $0.0 == mic.0 ? (clean, cleanOffset) : $0 }
        }
        await report(0.12, "Загружаю модель в память")
        let activity: SpeechDetector
        if let existing = live ? liveActivity : nil { activity = existing } else { activity = try SpeechDetector(); if live { liveActivity = activity } }
        let model: ParakeetRecognitionSession
        if let existing = live ? liveModel : nil,
           existing.primaryDirectory == modelDirectory.standardizedFileURL,
           existing.verifierDirectory == verifierDirectory.standardizedFileURL {
            model = existing
        } else {
            model = try measureRecognition("parakeetLoad") {
                try ParakeetRecognitionSession(primaryDirectory: modelDirectory, verifierDirectory: verifierDirectory)
            }
            if live { liveModel = model }
        }
        let voices: SpeakerEngine?
        if live, let existing = liveVoices { voices = existing }
        else {
            voices = FileManager.default.fileExists(atPath: speakerDirectory.appendingPathComponent("titanet.onnx").path)
                ? try measureRecognition("speakerLoad") { try SpeakerEngine(directory: speakerDirectory) } : nil
            if live { liveVoices = voices }
        }
        let russian: RussianSpeechRecognizer?
        if !russianVerification { russian = nil }
        else if live, let existing = liveRussian { russian = existing }
        else {
            // Existing/custom installations can still transcribe while the new
            // optional acoustic verifier is unavailable or cannot be loaded.
            russian = try? measureRecognition("gigaLoad") {
                try RussianSpeechRecognizer(directory: speakerDirectory.deletingLastPathComponent().appendingPathComponent(RussianSpeechRecognizer.directoryName))
            }
            if live { liveRussian = russian }
        }
        let firstPassTiming = beginPerformanceInterval()
        var firstPassTimingFinished = false
        defer { if !firstPassTimingFinished { endPerformanceInterval(firstPassTiming, kind: "firstPassTotal") } }
        var startedRecognition = false
        for (fileIndex, item) in preparedFiles.sorted(by: { !$0.0.lastPathComponent.contains("-mic.") && $1.0.lastPathComponent.contains("-mic.") }).enumerated() {
            try Task.checkCancellation()
            let (url, offset) = item
            let track = (url == generated ? sourceMicrophone : nil)?.lastPathComponent ?? url.lastPathComponent
            if checkpoint?.firstPassComplete == true { break }
            if checkpoint?.completedTracks.contains(track) == true { continue }
            let file = try AVAudioFile(forReading: url)
            let sourceFormat = file.processingFormat
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false), let converter = AVAudioConverter(from: sourceFormat, to: target) else { throw PisaError.message("Не удалось прочитать формат аудио") }
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
            let completed = checkpoint?.rangesCompleted[track] ?? 0
            for (rangeIndex, range) in ranges.enumerated().dropFirst(completed) {
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
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputFrames) else { throw PisaError.message("Не удалось преобразовать аудио") }
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
                            ? [VoiceRegion(start: max(0, range.start - start), end: min(duration, range.end - start), embedding: nil)]
                            : voices.map { voices in
                                measureRecognition("diarization") { voices.regions(samples, extractEmbeddings: false) }
                            } ?? []
                        var protectedShortSpeech: [Range<Int>] = []
                        if !isMic {
                            // VAD recovers speech that segmentation missed. Acoustic
                            // probes can recover a voice only when independent parts
                            // agree; short or conflicting evidence stays unidentified.
                            func sampleRange(_ region: VoiceRegion) -> Range<Int> {
                                Int((region.start * 16000).rounded())..<Int((region.end * 16000).rounded())
                            }
                            let speech = activity.regions(samples).map(sampleRange)
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
                            let missing = SpeechCoverage.uncovered(speech: speech,
                                covered: covered, sampleCount: samples.count,
                                minimumPartialLength: 4800)
                            protectedShortSpeech = SpeechCoverage.shortSpeechHiddenByPadding(speech: speech,
                                diarized: regions.map(sampleRange), padded: covered, sampleCount: samples.count,
                                maximumLength: 8000, minimumPartialLength: 4800) { turn in
                                    !activity.regions(Array(samples[turn])).isEmpty
                                }
                            regions += missing.flatMap { gap in
                                voices?.recoveredRegions(samples, in: gap) ?? [VoiceRegion(
                                    start: Double(gap.lowerBound) / 16000, end: Double(gap.upperBound) / 16000,
                                    embedding: nil, recoveredSpeech: true)]
                            }
                            regions += protectedShortSpeech.map { turn in
                                VoiceRegion(start: Double(turn.lowerBound) / 16000, end: Double(turn.upperBound) / 16000,
                                    embedding: nil, recoveredSpeech: true, recoveryRange: turn)
                            }
                            regions.sort { $0.start < $1.start }
                        }
                        regions = regions.flatMap { region -> [VoiceRegion] in
                            let lower = max(0, Int(region.start * 16000))
                            let upper = min(samples.count, Int(region.end * 16000))
                            guard upper > lower else { return [] }
                            // Recovery already bounds recognition chunks and retains
                            // the verified vectors used to determine their boundaries.
                            if region.recoveredSpeech, upper - lower <= 24 * 16_000 + 1 { return [region] }
                            let chunks = SpeechChunking.ranges(in: samples, range: lower..<upper)
                            return chunks.map { chunk in
                                let input = SpeakerEmbeddingInput.forChunk(chunk, chunkCount: chunks.count,
                                    originalRange: region.embeddingRange, exclusions: region.embeddingExclusions,
                                    isMicrophone: isMic, recoveredSpeech: region.recoveredSpeech)
                                return VoiceRegion(start: Double(chunk.lowerBound) / 16000, end: Double(chunk.upperBound) / 16000,
                                    embedding: nil, recoveredSpeech: region.recoveredSpeech,
                                    embeddingExclusions: input?.exclusions ?? [], embeddingRange: input?.range)
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
                            var lower = max(0, Int((region.start - leading) * 16000))
                            var upper = min(samples.count, Int((region.end + trailing) * 16000))
                            if let gap = region.recoveryRange {
                                let evidence = Int((region.start * 16000).rounded())..<Int((region.end * 16000).rounded())
                                let context = SpeakerRecovery.recognitionRange(for: evidence, in: gap, padding: 1920)
                                lower = max(0, context.lowerBound)
                                upper = min(samples.count, context.upperBound)
                            }
                            guard upper > lower else { continue }
                            if !region.recoveredSpeech, !protectedShortSpeech.isEmpty {
                                let evidence = Int((region.start * 16000).rounded())..<Int((region.end * 16000).rounded())
                                let trimmed = SpeechCoverage.trimPadding(lower..<upper, around: evidence, avoiding: protectedShortSpeech)
                                lower = trimmed.lowerBound
                                upper = trimmed.upperBound
                            }
                            let regionSamples = Array(samples[lower..<upper])
                            // Confirm speech in the exact recovered evidence, not
                            // the recognition padding borrowed across an acoustic cut.
                            // Neighboring speech must not turn a silent part into text.
                            if region.recoveredSpeech {
                                let evidenceLower = max(0, Int((region.start * 16000).rounded()))
                                let evidenceUpper = min(samples.count, Int((region.end * 16000).rounded()))
                                guard evidenceUpper > evidenceLower,
                                      !activity.regions(Array(samples[evidenceLower..<evidenceUpper])).isEmpty else { continue }
                            }
                            let speech = (offset + start + region.start)..<(offset + start + region.end)
                            if !startedRecognition, case .lookahead(let window) = boundaryCheck, window.speechBlocksCut(speech) {
                                // A single early turn leaves no useful pause before
                                // the cut. Try the same input as the stopped fallback.
                                return WindowPass(retry: .withoutLookahead(isMic: isMic))
                            }
                            startedRecognition = true
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
                            let inferenceStarted = ContinuousClock.now
                            let recognized = try await recognize(regionSamples, speechStart: region.start - Double(lower) / 16000,
                                expandedSamples: expandedSamples, model: model,
                                russian: russian, vocabulary: context, duration: region.end - region.start, isMic: isMic,
                                diagnostic: collectDiagnostics ? (speech.lowerBound, url.lastPathComponent) : nil)
                            try await performance.pace(after: inferenceStarted)
                            guard let recognized else { continue }
                            let speaker = isMic ? "Я" : TranscriptSegment.unidentifiedSpeaker
                            var segment = TranscriptSegment(start: speech.lowerBound, end: speech.upperBound, speaker: speaker, text: recognized.text)
                            segment.independentRecognitionLanguage = recognized.independentLanguage
                            segment.audioFile = url.lastPathComponent
                            segment.embedding = region.embedding
                            segment.embeddingDuration = region.embeddingDuration
                            segment.speakerEvidenceIsMixed = region.speakerEvidenceIsMixed
                            if let range = region.embeddingRange {
                                let input = SpeakerEmbeddingInput(range: range, exclusions: region.embeddingExclusions)
                                segment.speakerEvidenceIsMixed = input.hasSustainedOverlap(sampleCount: samples.count,
                                    sampleRate: SpeakerEmbeddingExtractor.sampleRate)
                                let evidence = voices?.embedding(samples, in: range, excluding: region.embeddingExclusions)
                                segment.embedding = evidence?.vector
                                segment.embeddingDuration = evidence?.duration
                            }
                            recognized.recordEvidence(for: segment.id, in: firstPass)
                            firstPass.bounds[segment.id] = (start + Double(lower) / 16000)..<(start + Double(upper) / 16000)
                            if let gap = region.recoveryRange {
                                firstPass.recoveredAudio[segment.id] = .init(
                                    gap: (start + Double(gap.lowerBound) / 16000)..<(start + Double(gap.upperBound) / 16000),
                                    evidence: (start + region.start)..<(start + region.end))
                            }
                            firstPass.segments.append(segment)

                        }
                    }
                }
                position += AVAudioFramePosition(input.frameLength)
                let fraction = (Double(fileIndex) + Double(position) / Double(max(1, total))) / Double(preparedFiles.count)
                let recognitionProgress = 0.12 + fraction * (contextualVerification ? 0.73 : 0.88)
                if let checkpoint, let checkpointURL {
                    let firstRange = checkpoint.rangesCompleted.isEmpty
                    checkpoint.rangesCompleted[track] = rangeIndex + 1
                    checkpoint.progress = max(checkpoint.progress, recognitionProgress)
                    committedSegmentCount = firstPass.segments.count
                    try await ProtectedFileRead.waitForAccess(read: {
                        try checkpoint.save(to: checkpointURL, force: firstRange)
                    }, onDenied: {})
                }
                await report(recognitionProgress, "Распознаю · \(timecode(start + duration))")
            }
            checkpoint?.completedTracks.insert(track)
        }
        if let checkpoint, let checkpointURL, !checkpoint.firstPassComplete {
            checkpoint.firstPassComplete = true
            checkpoint.progress = contextualVerification ? 0.85 : 0.99
            try await ProtectedFileRead.waitForAccess(read: {
                try checkpoint.save(to: checkpointURL)
            }, onDenied: {})
        }
        if case .nominal(let window, let isMic) = boundaryCheck,
           !firstPass.segments.contains(where: { $0.audioFile?.contains("-mic.") == isMic && window.confirmedSpeechThroughCut($0) }) {
            // Restore the full path before this trial can update live language history.
            return WindowPass(retry: .withLookahead)
        }
        endPerformanceInterval(firstPassTiming, kind: "firstPassTotal")
        firstPassTimingFinished = true
        var sorted = firstPass.segments.sorted { $0.start < $1.start }
        if contextualVerification {
            sorted = try await contextualRevision(sorted, preceding: preceding,
                files: preparedFiles, bounds: firstPass.bounds, hypotheses: firstPass.hypotheses, model: model, russian: russian,
                vocabulary: context,
                performance: performance, collectDiagnostics: collectDiagnostics,
                checkpoint: checkpoint, checkpointURL: checkpointURL, progress: report)
        }
        let finalizationTiming = beginPerformanceInterval()
        defer { endPerformanceInterval(finalizationTiming, kind: "finalizationTotal") }
        if let first = sorted.first, let previous = recentLanguageSegments.first, first.start <= previous.start { recentLanguageSegments = [] }
        if live, recentLanguageSegments.isEmpty {
            recentLanguageSegments = preceding.filter(BackchannelLanguage.canRestoreLanguageAnchor)
        }
        let languageResolved = resolveLanguage(sorted, evidence: firstPass, preceding: live ? recentLanguageSegments : [], vocabulary: context)
        var localized = zip(sorted, languageResolved).map { original, segment in
                var revised = segment
                if live {
                    revised.independentRecognitionLanguage = original.independentRecognitionLanguage != false
                        && original.text == segment.text && firstPass.lexicalBackchannels[segment.id] == nil
                        && !firstPass.uncertainShortLanguage.contains(segment.id)
                }
                revised.text = TranscriptOrthography.normalize(segment.text, vocabulary: context)
                if !retainProcessedMicrophone, let generated, revised.audioFile == generated.lastPathComponent {
                    revised.audioFile = sourceMicrophone?.lastPathComponent
                }
                return revised
            }
        // Shared context can decode one physical word twice, or damage both
        // pieces of a cut word. Cached acoustic anchors gate any extra replay;
        // differing forms additionally require an unprompted full Qwen decode.
        if let russian {
            for pair in RecognitionBoundaryRepair.adjacentPairs(localized) {
                let left = localized[pair.left], right = localized[pair.right]
                guard let a = firstPass.recoveredAudio[left.id], let b = firstPass.recoveredAudio[right.id], a.gap == b.gap,
                      abs(a.evidence.upperBound - b.evidence.lowerBound) < 1.0 / 16000,
                      left.audioFile == right.audioFile, let fileName = left.audioFile,
                      let url = preparedFiles.first(where: { $0.0.lastPathComponent == fileName })?.0,
                      let leftBounds = firstPass.bounds[left.id], let rightBounds = firstPass.bounds[right.id],
                      let leftHypothesis = firstPass.hypotheses[left.id], let rightHypothesis = firstPass.hypotheses[right.id],
                      leftHypothesis.words.count >= 2, rightHypothesis.words.count >= 2 else { continue }
                let lower = max(leftBounds.lowerBound, rightBounds.lowerBound)
                let upper = min(leftBounds.upperBound, rightBounds.upperBound)
                guard upper > lower else { continue }
                func shifted(_ words: [RecognitionTimedWord], by offset: Double) -> [RecognitionTimedWord] {
                    words.map { RecognitionTimedWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
                }
                let leftWords = shifted(leftHypothesis.words, by: leftBounds.lowerBound)
                let rightWords = shifted(rightHypothesis.words, by: rightBounds.lowerBound)
                let exactDuplicate = RecognitionBoundaryOverlap.candidate(left: left.text, right: right.text) != nil
                let repairProbe = RecognitionBoundaryRepair.probe(left: left.text, right: right.text,
                    leftWords: leftWords, rightWords: rightWords, cut: b.evidence.lowerBound, sharedAudio: lower..<upper)
                guard exactDuplicate || repairProbe != nil else { continue }
                let union = a.gap.upperBound - a.gap.lowerBound <= 30
                    ? a.gap : leftBounds.lowerBound..<rightBounds.upperBound
                guard union.upperBound - union.lowerBound <= 30 else { continue }
                try Task.checkCancellation()
                guard let samples = try? Self.contextSamples(url, start: union.lowerBound, end: union.upperBound) else { continue }
                let began = ContinuousClock.now
                let evidence = acousticRecognition(samples, using: russian)
                try await performance.pace(after: began)
                try Task.checkCancellation()
                guard let evidence else { continue }
                let words = shifted(evidence.words, by: union.lowerBound)
                if exactDuplicate, let revised = RecognitionBoundaryOverlap.revisedRight(left: left.text, right: right.text,
                    leftWords: leftWords, rightWords: rightWords, unionWords: words, cut: b.evidence.lowerBound,
                    sharedAudio: lower..<upper) {
                    localized[pair.right].text = revised
                    if collectDiagnostics {
                        contextDiagnostics.append(["kind": "shared-boundary-word", "start": String(right.start),
                            "source": right.text, "candidate": revised])
                    }
                    continue
                }
                guard let repairProbe, let proposal = RecognitionBoundaryRepair.proposal(repairProbe, unionWords: words) else { continue }
                try Task.checkCancellation()
                let replayBegan = ContinuousClock.now
                let maxTokens = min(768, max(96, Int(Double(samples.count) / 16000 * 20)))
                guard model.canVerify else { continue }
                let verifier: Qwen3ASRModel
                do { verifier = try await verificationModel(model) }
                catch is ParakeetRecognitionSession.VerifierUnavailable { continue }
                let reread = verify(samples, with: verifier, session: model, maxTokens: maxTokens,
                                    context: "", language: "Russian")
                try await performance.pace(after: replayBegan)
                try Task.checkCancellation()
                guard reread.language?.lowercased() == "russian",
                      let revision = RecognitionBoundaryRepair.confirm(proposal, reread: reread.text, normalizeReplacement: { token in
                          TranscriptOrthography.normalize(spokenVocabulary.apply(to: token), vocabulary: context)
                      }) else { continue }
                localized[pair.left].text = revision.left
                localized[pair.right].text = revision.right
                if collectDiagnostics {
                    contextDiagnostics.append(["kind": "shared-boundary-repair", "start": String(right.start),
                        "sourceLeft": left.text, "source": right.text,
                        "candidateLeft": revision.left, "candidate": revision.right,
                        "independent": evidence.text, "reread": reread.text])
                }
            }
        }
        if live, let end = localized.map(\.end).max() {
            // A context-dependent correction must not establish the language of
            // later windows, and its disproven Latin source is not an anchor.
            let independent = localized.filter(BackchannelLanguage.canRestoreLanguageAnchor)
            recentLanguageSegments = (recentLanguageSegments + independent).filter { $0.end >= end - 60 }
        }
        try Task.checkCancellation()
        if let generated, localized.contains(where: { $0.audioFile == generated.lastPathComponent }) {
            if scratch != nil, let sourceMicrophone {
                let retained = sourceMicrophone.deletingLastPathComponent().appendingPathComponent(generated.lastPathComponent)
                try FileManager.default.moveItem(at: generated, to: retained)
            }
            keepGenerated = true
        }
        guard !live, let profiles else { return WindowPass(segments: localized) }
        return WindowPass(segments: SpeakerClustering.assign(localized, profiles: profiles))
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
        modelDirectory: URL, speakerDirectory: URL, verifierDirectory: URL? = nil, vocabulary: String, selected: Set<UUID>,
        suppliedBounds: [UUID: Range<Double>], repeatFirstPass: Bool) async throws -> [TranscriptSegment] {
        contextDiagnostics = []
        prepareVocabulary(vocabulary)
        let priorLimit = Memory.cacheLimit
        Memory.cacheLimit = 256 * 1024 * 1024
        defer { Memory.clearCache(); Memory.cacheLimit = priorLimit }
        let model = try measureRecognition("parakeetLoad") {
            try ParakeetRecognitionSession(primaryDirectory: modelDirectory,
                verifierDirectory: ParakeetRecognitionPolicy.verifierDirectory(explicit: verifierDirectory, speakerDirectory: speakerDirectory))
        }
        let russian = try measureRecognition("gigaLoad") {
            try RussianSpeechRecognizer(directory: speakerDirectory.deletingLastPathComponent()
                .appendingPathComponent(RussianSpeechRecognizer.directoryName))
        }
        var segments = frozen.sorted { $0.start < $1.start }
        var bounds = suppliedBounds
        let firstPass = BatchTranscriptionCheckpoint.FirstPass()
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
                   let recognized = try await recognize(samples, speechStart: segment.start - offset - interval.lowerBound,
                                                  expandedSamples: nil, model: model, russian: russian,
                                                  vocabulary: vocabulary, duration: segment.end - segment.start,
                                                  isMic: name.contains("-mic."), diagnostic: (segment.start, name)) {
                    segments[index].text = recognized.text
                    segments[index].independentRecognitionLanguage = recognized.independentLanguage
                    recognized.recordEvidence(for: segment.id, in: firstPass)
                } else {
                    firstPass.hypotheses[segment.id] = acousticRecognition(samples, using: russian)
                }
            }
        }
        let revised = try await contextualRevision(segments, preceding: [], files: files, bounds: bounds,
            hypotheses: firstPass.hypotheses, model: model, russian: russian, vocabulary: vocabulary,
            performance: TranscriptionPerformance(), collectDiagnostics: true, selected: selected) { _, _ in }
        guard repeatFirstPass else { return revised }
        return resolveLanguage(revised, evidence: firstPass, preceding: [], vocabulary: vocabulary)
    }

    private func resolveLanguage(_ segments: [TranscriptSegment], evidence: BatchTranscriptionCheckpoint.FirstPass,
                                 preceding: [TranscriptSegment], vocabulary: String) -> [TranscriptSegment] {
        BackchannelLanguage.resolve(segments, alternatives: evidence.backchannels,
            lexicalAlternatives: evidence.lexicalBackchannels, uncertain: evidence.uncertainShortLanguage,
            preceding: preceding, vocabulary: vocabulary)
    }

    private struct RecognizedSpeech {
        var text: String
        var russianBackchannel: String?
        var russianLexical: String?
        var uncertainLanguage = false
        var independentLanguage: Bool?
        var acoustic: RecognitionAcousticResult?

        func recordEvidence(for id: UUID, in firstPass: BatchTranscriptionCheckpoint.FirstPass) {
            firstPass.backchannels[id] = russianBackchannel
            firstPass.lexicalBackchannels[id] = russianLexical
            if uncertainLanguage { firstPass.uncertainShortLanguage.insert(id) }
            firstPass.hypotheses[id] = acoustic
        }
    }

    /// Use a frozen, chronological first pass from both tracks. A proposed
    /// correction never becomes evidence for a later correction in this pass.
    private func contextualRevision(_ segments: [TranscriptSegment], preceding: [TranscriptSegment],
        files: [(URL, Double)], bounds: [UUID: Range<Double>], hypotheses: [UUID: RecognitionAcousticResult], model: ParakeetRecognitionSession,
        russian: RussianSpeechRecognizer?, vocabulary: String, performance: TranscriptionPerformance, collectDiagnostics: Bool,
        selected: Set<UUID>? = nil, checkpoint: BatchTranscriptionCheckpoint? = nil, checkpointURL: URL? = nil,
        progress: @escaping @Sendable (Double, String) async -> Void) async throws -> [TranscriptSegment] {
        let contextTiming = beginPerformanceInterval()
        defer { endPerformanceInterval(contextTiming, kind: "contextTotal") }
        guard let russian, model.canVerify else {
            try Task.checkCancellation()
            if collectDiagnostics {
                contextDiagnostics += segments.map { ["start": String($0.start), "track": $0.audioFile ?? "",
                    "source": $0.text, "independent": hypotheses[$0.id]?.text ?? "", "kind": "first-pass"] }
            }
            await progress(1, "Расшифровка готова")
            return segments
        }
        let snapshot = RecognitionContext(segments: segments, preceding: preceding)
        var revised = segments
        do {
        let start = min(max(0, checkpoint?.revisionCount ?? 0), segments.count)
        for index in 0..<start {
            if let text = checkpoint?.revisions[revised[index].id] { revised[index].text = text }
        }
        func saveRevision(through index: Int, force: Bool) async throws {
            guard let checkpoint, let checkpointURL else { return }
            let fraction = 0.85 + 0.15 * Double(index + 1) / Double(segments.count)
            checkpoint.recordRevision(index: index, segment: segments[index], text: revised[index].text, progress: fraction)
            try await ProtectedFileRead.waitForAccess(read: {
                try checkpoint.save(to: checkpointURL, force: force)
            }, onDenied: {})
        }
        for (index, segment) in segments.enumerated().dropFirst(start) {
            // Reaching the next iteration also commits utterances that needed no edits.
            if index > start { try await saveRevision(through: index - 1, force: false) }
            try Task.checkCancellation()
            if let selected, !selected.contains(segment.id) { continue }
            if collectDiagnostics {
                contextDiagnostics.append(["start": String(segment.start), "track": segment.audioFile ?? "",
                    "source": segment.text, "independent": hypotheses[segment.id]?.text ?? "", "kind": "first-pass"])
            }
            guard let name = segment.audioFile, let (url, offset) = files.first(where: { $0.0.lastPathComponent == name }),
                  let audioRange = bounds[segment.id] else { continue }
            let duration = segment.end - segment.start
            guard duration <= 30 else { continue }
            if let anchor = snapshot.shortReplyAnchor(for: segment, vocabulary: vocabulary) {
                let start = segment.start - offset
                if let isolated = try? Self.contextSamples(url, start: start, end: segment.end - offset),
                   let heard = acousticRecognition(isolated, using: russian), RussianRecognition.words(heard.text).count == 1,
                   let wide = try? Self.contextSamples(url, start: start - 0.35, end: anchor.end - offset), !wide.isEmpty {
                    let began = ContinuousClock.now
                    let verifier = try await verificationModel(model)
                    func readAnchor(_ clip: [Float]) throws -> STTOutput {
                        try Task.checkCancellation()
                        return verify(clip, with: verifier, session: model, maxTokens: 384,
                                      context: "", language: nil)
                    }
                    let checked = try readAnchor(wide)
                    var accepted: String?
                    if let candidate = anchor.candidate(isolated: heard.text, wide: checked.text, language: checked.language),
                       let earlier = try? Self.contextSamples(url, start: anchor.start - offset, end: segment.end - offset + 0.25),
                       !earlier.isEmpty {
                        let prior = try readAnchor(earlier)
                        if anchor.confirmsPreceding(candidate, wide: prior.text, language: prior.language) { accepted = candidate }
                    }
                    if collectDiagnostics {
                        contextDiagnostics.append(["kind": "short-reply-anchor", "start": String(segment.start),
                            "source": segment.text, "independent": heard.text, "reread": checked.text,
                            "language": checked.language ?? "", "candidate": accepted ?? ""])
                    }
                    try await performance.pace(after: began)
                    if let accepted { revised[index].text = accepted; continue }
                }
            }
            // A brief interruption can be wholly contained in another turn
            // on the same track. In that case the original decode has no room
            // for padding. Verify the word itself before using either margin.
            if let overlap = snapshot.overlappingWord(for: segment, vocabulary: vocabulary) {
                let start = segment.start - offset, end = segment.end - offset
                let margin = RecognitionContext.OverlappingWord.padding
                if start >= margin,
                   let core = try? Self.contextSamples(url, start: start, end: end),
                   let padded = try? Self.contextSamples(url, start: start - margin, end: end + margin),
                   !core.isEmpty, padded.count >= core.count + Int(2 * margin * 16000) - 2,
                   let exact = acousticRecognition(core, using: russian), let wide = acousticRecognition(padded, using: russian),
                   let word = overlap.acousticWord(core: exact.text, padded: wide.text) {
                    let began = ContinuousClock.now
                    let verifier = try await verificationModel(model)
                    func reread(_ samples: [Float]) throws -> String? {
                        func generate(_ language: String?) throws -> STTOutput {
                            try Task.checkCancellation()
                            return verify(samples, with: verifier, session: model, maxTokens: 96,
                                          context: "", language: language)
                        }
                        let detected = try generate(nil)
                        guard !overlap.confirmsSource(detected.text) else { return nil }
                        if detected.language?.lowercased() == "russian" { return detected.text }
                        return try generate("Russian").text
                    }
                    let narrow = try reread(core)
                    let wider = narrow.map(RussianRecognition.words) == [word] ? try reread(padded) : nil
                    let accepted = overlap.confirmedText(word: word, core: narrow ?? "", padded: wider ?? "")
                    if collectDiagnostics {
                        contextDiagnostics.append(["kind": "overlapping-word", "start": String(segment.start),
                            "source": segment.text, "coreAcoustic": exact.text, "paddedAcoustic": wide.text,
                            "coreVerifier": narrow ?? "", "paddedVerifier": wider ?? "", "candidate": accepted ?? ""])
                    }
                    try await performance.pace(after: began)
                    if let accepted { revised[index].text = accepted; continue }
                }
            }
            let (neighbors, vocabulary) = measureRecognition("contextVocabulary") {
                let neighbors = snapshot.neighbors(around: segment)
                let vocabulary = spokenVocabulary.contextualVocabulary(in:
                    [segment.text, hypotheses[segment.id]?.text ?? ""] + neighbors.preceding + neighbors.following)
                return (neighbors, vocabulary)
            }
            var regionSamples: [Float]?
            func readRegion() -> [Float]? {
                if let regionSamples { return regionSamples }
                let loaded = try? measureRecognition("contextPCM") {
                    try Self.contextSamples(url, start: audioRange.lowerBound, end: audioRange.upperBound)
                }
                regionSamples = loaded
                return loaded
            }
            if let repair = snapshot.scriptRepair(for: segment, vocabulary: vocabulary, neighbors: neighbors) {
                let start = segment.start - offset, end = segment.end - offset
                let lower = max(0, start - 4), upper = end + 2
                if let wide = try? Self.contextSamples(url, start: lower, end: upper),
                   let evidence = acousticRecognition(wide, using: russian), !evidence.words.isEmpty,
                   let core = readRegion(), !core.isEmpty {
                    let began = ContinuousClock.now
                    let verifier = try await verificationModel(model)
                    func autoRead(_ samples: [Float]) -> STTOutput {
                        let maxTokens = max(96, Int(Double(samples.count) / 16000 * 24))
                        return verify(samples, with: verifier, session: model, maxTokens: maxTokens,
                                      context: "", language: nil)
                    }
                    let coreRead = autoRead(core)
                    if !["ukrainian", "belarusian"].contains(coreRead.language?.lowercased() ?? ""),
                       !BackchannelLanguage.confirmsCyrillicSource(original: segment.text, reread: coreRead.text, language: coreRead.language) {
                        try Task.checkCancellation()
                        // An independently framed multilingual read reduces a shared
                        // boundary's influence on clipped letter names.
                        let checkAudio = repair.terms.isEmpty || !repair.scriptMismatch ? wide
                            : (try? Self.contextSamples(url, start: max(0, start - 3.7), end: end + 1.3)) ?? wide
                        let check = autoRead(checkAudio)
                        let primary = measureRecognition("parakeet") { model.generate(wide) }.text
                        // The padded clip and both wide reads can absorb a neighbor's
                        // ending. Isolate exactly the same turn as the first pass.
                        var isolated: STTOutput?
                        if repair.scriptMismatch, repair.terms.isEmpty,
                           let range = SpeechCoverage.unpaddedShortTurn(start: start - audioRange.lowerBound,
                               duration: duration, sampleCount: core.count, includeAlreadyIsolated: true) {
                            isolated = range.count == core.count ? coreRead : autoRead(Array(core[range]))
                        }
                        let candidate = repair.revised(acoustic: evidence, target: (start - lower)..<(end - lower),
                            primary: primary, verifier: check.text, language: check.language,
                            isolated: isolated.map { ($0.text, $0.language) }, confirmWord: { range in
                                guard let clip = SpeechCoverage.unpaddedTurn(start: range.lowerBound,
                                    duration: range.upperBound - range.lowerBound, sampleCount: wide.count,
                                    minimumPadding: 0) else { return nil }
                                let local = autoRead(Array(wide[clip]))
                                return (local.text, local.language)
                            })
                        if collectDiagnostics {
                            contextDiagnostics.append(["kind": "wide-script", "start": String(segment.start),
                                "source": segment.text, "independent": evidence.text, "primary": primary,
                                "reread": check.text, "language": check.language ?? "", "isolated": isolated?.text ?? "",
                                "isolatedLanguage": isolated?.language ?? "", "candidate": candidate ?? ""])
                        }
                        if let candidate { revised[index].text = candidate }
                    }
                    try await performance.pace(after: began)
                    try Task.checkCancellation()
                    if revised[index].text != segment.text { continue }
                }
            }
            if duration < 2 {
                guard RecognitionContext.isWordRichShortTurn(segment.text, duration: duration),
                      let samples = readRegion(),
                      let heard = hypotheses[segment.id]?.text ?? acousticRecognition(samples, using: russian)?.text,
                      (4...6).contains(RussianRecognition.words(heard).count),
                      RussianRecognition.words(heard) != RussianRecognition.words(segment.text) else { continue }
                let hints = spokenVocabulary.relevantTerms(in: [segment.text, heard])
                for prompt in (hints.isEmpty ? [""] : [hints, ""]) {
                    try Task.checkCancellation()
                    let verifier = try await verificationModel(model)
                    let output = RecognitionPromptEcho.decode(context: prompt, vocabulary: prompt, text: { $0.text }) {
                        let prompt = $0
                        return verify(samples, with: verifier, session: model, maxTokens: 96,
                                      context: prompt, language: "Russian")
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
            let independent = hypotheses[segment.id]?.text
            if let independent, let word = snapshot.recurringWord(for: segment, independent: independent, vocabulary: vocabulary),
               let samples = readRegion(), !samples.isEmpty {
                let began = ContinuousClock.now
                try Task.checkCancellation()
                let verifier = try await verificationModel(model)
                let tokens = min(768, max(96, Int(Double(samples.count) / 16000 * 20)))
                let output = verify(samples, with: verifier, session: model, maxTokens: tokens,
                                    context: "", language: nil)
                try await performance.pace(after: began)
                try Task.checkCancellation()
                if let confirmed = word.confirmedText(language: output.language, reread: output.text) {
                    revised[index].text = confirmed
                    if collectDiagnostics {
                        contextDiagnostics.append(["kind": "recurring-word", "start": String(segment.start),
                            "source": segment.text, "independent": independent, "candidate": confirmed])
                    }
                    continue
                }
            }
            // Lexical disagreements at the region's first/last words have no
            // glossary term and no second text anchor. Re-listen without a
            // prompt, then require exact agreement with the other recognizer.
            if duration <= 12, let independent,
               RecognitionConsensus.hasBoundaryDisagreement(original: segment.text,
                    corroboration: independent, vocabulary: vocabulary),
               let samples = readRegion(),
               !samples.isEmpty {
                let boundaryBegan = ContinuousClock.now
                try Task.checkCancellation()
                let maxTokens = min(768, max(96, Int(Double(samples.count) / 16000 * 20)))
                let verifier = try await verificationModel(model)
                let output = verify(samples, with: verifier, session: model, maxTokens: maxTokens,
                                    context: "", language: "Russian")
                let candidate = spokenVocabulary.apply(to: output.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if collectDiagnostics {
                    contextDiagnostics.append(["start": String(segment.start), "kind": "boundary-consensus",
                        "source": segment.text, "independent": independent, "candidate": candidate])
                }
                let phrases = RecognitionConsensus.hasBoundaryOnsetShape(original: segment.text, corroboration: independent)
                    ? snapshot.establishedPhrases(around: segment) : []
                var expandedEvidence: String?
                if RecognitionConsensus.needsBoundaryOnsetVerification(original: segment.text,
                    corroboration: independent, vocabulary: vocabulary, establishedPhrases: phrases),
                   let expanded = try? Self.contextSamples(url, start: max(0, audioRange.lowerBound - 1.5),
                                                          end: audioRange.upperBound + 1.5) {
                    expandedEvidence = acousticRecognition(expanded, using: russian)?.text
                    if collectDiagnostics {
                        contextDiagnostics.append(["start": String(segment.start), "kind": "boundary-expanded-acoustic",
                            "independent": expandedEvidence ?? ""])
                    }
                }
                try await performance.pace(after: boundaryBegan)
                try Task.checkCancellation()
                if let accepted = RecognitionConsensus.revisedBoundaryText(original: segment.text,
                    candidate: candidate, corroboration: independent, vocabulary: vocabulary,
                    establishedPhrases: phrases, expandedCorroboration: expandedEvidence) {
                    revised[index].text = accepted
                    if collectDiagnostics {
                        contextDiagnostics.append(["start": String(segment.start), "kind": "accepted",
                            "source": segment.text, "candidate": accepted])
                    }
                    continue
                }
            }
            let retry = measureRecognition("contextPlan") {
                snapshot.plan(for: segment, independent: independent,
                              vocabulary: vocabulary, spokenVocabulary: spokenVocabulary, neighbors: neighbors)
            }
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
            guard let samples = readRegion(), !samples.isEmpty else { continue }
            let acoustic = hypotheses[segment.id] ?? acousticRecognition(samples, using: russian)
            let began = ContinuousClock.now
            func decode(_ prompt: String, samples: [Float], retry: RecognitionContext.Retry,
                        applyVocabulary: Bool = true) async throws -> String {
                let verifier = try await verificationModel(model)
                func generate(_ context: String) throws -> STTOutput {
                    try Task.checkCancellation()
                    let maxTokens = min(768, max(96, Int(Double(samples.count) / 16000 * 20)))
                    return verify(samples, with: verifier, session: model, maxTokens: maxTokens,
                                  context: context, language: "Russian")
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
                          retry: RecognitionContext.Retry, prompt: String, kind: String) async throws -> String? {
                let candidate = try await decode(prompt, samples: samples, retry: retry)
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
                         kind: String) async throws -> String? {
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
                var approved: [String] = []
                probe: for range in ranges.prefix(2) {
                    try Task.checkCancellation()
                    let lower = max(0, min(samples.count, Int(range.lowerBound * 16000)))
                    let upper = max(lower, min(samples.count, Int(range.upperBound * 16000)))
                    guard upper > lower else { continue }
                    let clip = Array(samples[lower..<upper])
                    let heard = acousticRecognition(clip, using: russian)
                    if let heard, let joined = RecognitionContext.reconcileObservedInitialismBoundary(
                        original: segment.text, independent: heard.text, retry: retry, vocabulary: vocabulary) {
                        if collectDiagnostics {
                            contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-boundary",
                                "source": segment.text, "independent": heard.text, "candidate": joined])
                        }
                        approved.append(joined)
                        continue probe
                    }
                    var cropApproved = false
                    if let revised = try await consider(clip, evidence: heard, source: segment.text, retry: retry, prompt: retry.hints, kind: kind) {
                        approved.append(revised)
                        cropApproved = true
                    }
                    if let revised = RecognitionContext.revisedAnchoredDictionaryText(original: segment.text,
                        candidate: lastCandidate, corroboration: evidence.text, retry: retry, vocabulary: vocabulary) {
                        approved.append(revised)
                        cropApproved = true
                        if collectDiagnostics {
                            contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-anchored-dictionary",
                                "source": segment.text, "candidate": revised, "independent": evidence.text])
                        }
                    }
                    if let revised = RecognitionContext.revisedAnchoredDictionaryText(original: segment.text,
                        candidate: evidence.text, corroboration: lastCandidate, retry: retry, vocabulary: vocabulary,
                        candidateFromIndependentAudio: true) {
                        approved.append(revised)
                        cropApproved = true
                        if collectDiagnostics {
                            contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-independent-dictionary",
                                "source": segment.text, "candidate": revised, "independent": evidence.text])
                        }
                    }
                    // Either acoustic model can supply the exact glossary
                    // spelling. When the independent model hears an already
                    // established term, corroborate it with an unprompted
                    // reread, rather than requiring Qwen to spell it first.
                    if let heard {
                        let canonical = spokenVocabulary.apply(to: heard.text)
                        if retry.hasEstablishedAcousticTerm(in: canonical) {
                            let unprompted = try await decode("", samples: clip, retry: retry)
                            if collectDiagnostics {
                                contextDiagnostics.append(["start": String(segment.start), "kind": kind + "-independent",
                                    "source": segment.text, "candidate": canonical, "independent": unprompted])
                            }
                            if let revised = RecognitionContext.revisedText(original: segment.text, candidate: canonical,
                                corroboration: unprompted, retry: retry, vocabulary: vocabulary) {
                                approved.append(revised)
                                cropApproved = true
                            }
                        }
                    }
                    if cropApproved { continue probe }
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
                            let probe = try await decode("", samples: probeSamples, retry: retry, applyVocabulary: false)
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
                                let expandedCandidate = try await decode(retry.hints, samples: expandedProbe, retry: retry)
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
                                approved.append(disambiguated)
                                continue probe
                            }
                        }
                    }
                    if checkBoundary, let heard {
                        let a = max(0, lower - 4_800), b = min(samples.count, upper + 4_800)
                        if a > 0 || b < samples.count {
                            let wide = try await decode("", samples: samples, retry: retry, applyVocabulary: false)
                            let narrow = try await decode("", samples: Array(samples[a..<b]), retry: retry, applyVocabulary: false)
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
                                approved.append(boundary)
                                continue probe
                            }
                        }
                    }
                    if let heard, !heard.text.isEmpty {
                        let prompt = RussianRecognition.context(vocabulary: retry.hints,
                            hypothesis: spokenVocabulary.promptHypothesis(heard.text))
                        if let revised = try await consider(clip, evidence: heard, source: segment.text, retry: retry, prompt: prompt, kind: kind + "-acoustic") { approved.append(revised); continue probe }
                    }
                }
                return RecognitionContext.mergeIndependentRevisions(original: segment.text, revisions: approved)
            }
            var accepted: String?
            if let retry {
                accepted = try await consider(samples, evidence: acoustic, source: segment.text, retry: retry,
                                        prompt: retry.hints, kind: "hints")
                if accepted == nil { accepted = try await focused(samples, evidence: acoustic, retry: retry, kind: "focus") }
                if accepted == nil, retry.context != retry.hints {
                    accepted = try await consider(samples, evidence: acoustic, source: segment.text, retry: retry,
                                            prompt: retry.context, kind: "neighbors")
                }
            }
            if accepted == nil, let continuation {
                let end = min(continuation.segment.end - offset, continuation.segment.start - offset + 3.5)
                if end > audioRange.upperBound + 0.2,
                   let expanded = try? Self.contextSamples(url, start: audioRange.lowerBound, end: end),
                   let heard = acousticRecognition(expanded, using: russian) {
                    var joined = segment
                    joined.text += continuation.suffix
                    let boundaryRetry = measureRecognition("contextPlan") {
                        snapshot.plan(for: joined, independent: heard.text, vocabulary: vocabulary,
                                      spokenVocabulary: spokenVocabulary, neighbors: neighbors)
                    }
                    if let boundaryRetry {
                        let replacement = try await consider(expanded, evidence: heard, source: joined.text, retry: boundaryRetry,
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
            try await performance.pace(after: began)
        }
        if start < segments.count { try await saveRevision(through: segments.count - 1, force: true) }
        try Task.checkCancellation()
        await progress(1, "Расшифровка готова")
        return revised
        } catch is ParakeetRecognitionSession.VerifierUnavailable {
            return revised
        }
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
            throw PisaError.message("Не удалось прочитать аудио для уточнения расшифровки")
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

    private func recognize(_ samples: [Float], speechStart: Double, expandedSamples: [Float]?, model: ParakeetRecognitionSession, russian: RussianSpeechRecognizer?, vocabulary: String, duration: Double, isMic: Bool,
                           diagnostic: (start: Double, track: String)? = nil) async throws -> RecognizedSpeech? {
        let recognitionTiming = beginPerformanceInterval()
        defer { endPerformanceInterval(recognitionTiming, kind: "recognizeTotal") }
        let maxTokens = min(768, max(64, Int(duration * 16)))
        // On brief replies the vocabulary can be longer than the speech itself.
        let decodingVocabulary = spokenVocabulary.decodingVocabulary
        let context = duration >= 2 ? vocabulary : ""
        func generate(language: String?, context: String, audioSamples: [Float]? = nil, promptVocabulary: String? = nil) async throws -> STTOutput {
            let verifier = try await verificationModel(model)
            return try RecognitionPromptEcho.decode(context: context, vocabulary: promptVocabulary ?? vocabulary, text: { $0.text }) { prompt in
                try Task.checkCancellation()
                return verify(audioSamples ?? samples, with: verifier, session: model, maxTokens: maxTokens,
                              context: prompt, language: language)
            }
        }
        let shortMic = isMic && duration <= 1.5
        var result: STTOutput
        if shortMic {
            result = try await decodeShortMicrophone(model.primary, audio: MLXArray(samples))
        } else {
            result = measureRecognition("parakeet") { model.generate(samples) }
        }
        if let diagnostic {
            contextDiagnostics.append(["kind": "primary", "engine": "parakeet-tdt-v3",
                "start": String(diagnostic.start), "track": diagnostic.track, "source": result.text])
        }
        // This is an exceptional invalid-output reread, not a second primary
        // decoder. Do not replace valid Parakeet turns or force foreign Latin
        // speech into Russian merely because no language tag was emitted.
        if MeetingSpeechText.containsForeignLetters(result.text), model.canVerify {
            do {
                let checked = try await generate(language: nil, context: "")
                if MeetingSpeechText.accepts(checked.text) { result = checked }
            } catch is ParakeetRecognitionSession.VerifierUnavailable { }
        }
        var primaryText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var spellingEvidence: RecognitionAcousticResult?
        if RussianRecognition.needsScriptSpellingCheck(primaryText) {
            try Task.checkCancellation()
            spellingEvidence = acousticRecognition(samples, using: russian)
            if let heard = spellingEvidence?.text {
                let repair = RussianRecognition.cyrillicSpelling(original: primaryText, heard: heard, vocabulary: vocabulary)
                if let repair, repair.confirmedByRepetition {
                    primaryText = repair.text
                } else if model.canVerify {
                    let local = RussianRecognition.localScriptSpelling(original: primaryText, heard: heard, vocabulary: vocabulary)
                    if repair != nil || local != nil {
                        do {
                            let reread = try await generate(language: nil, context: "")
                            primaryText = repair?.confirmedText(language: reread.language, reread: reread.text)
                                ?? local?.confirmedText(language: reread.language, reread: reread.text) ?? primaryText
                        } catch is ParakeetRecognitionSession.VerifierUnavailable { }
                    }
                }
            }
        }
        // Parakeet does not detect language. Its echoed/default language field
        // must never force a Russian retry or suppress Russian quality checks.
        let isRussian = ParakeetRecognitionPolicy.hasRussianTextEvidence(primaryText)
        var acoustic = isRussian ? spellingEvidence : nil
        var text = BackchannelLanguage.sourceForLanguageCheck(primary: primaryText, formatted: spokenVocabulary.apply(to: primaryText),
            duration: duration, vocabulary: vocabulary)
        var uncertainLanguage = false
        guard text.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
              !MeetingSpeechText.containsForeignLetters(text) else { return nil }
        let fillerSpelling = text.utf8.contains { (65...90).contains($0) || (97...122).contains($0) }
            ? BackchannelLanguage.russianSpelling(ofFiller: text) : nil
        var needsLexicalCheck = fillerSpelling == nil && BackchannelLanguage.shouldRecheckLexical(text, duration: duration, vocabulary: vocabulary)
        var unverifiedLanguage: Bool? { duration <= 2 && !isRussian && needsLexicalCheck ? false : nil }
        try Task.checkCancellation()
        guard model.canVerify else {
            return RecognizedSpeech(text: text, independentLanguage: unverifiedLanguage,
                acoustic: acoustic ?? (isRussian && duration >= 2
                ? acousticRecognition(samples, using: russian) : nil))
        }
        do {
        // An extra group of zeros changes the amount while leaving the rest of the
        // sentence intact. Only ask the verifier when the acoustic reading is shorter.
        if RecognitionNumberMagnitude.needsVerification(primaryText),
           isRussian || RecognitionNumberMagnitude.isStandaloneCandidate(primaryText) {
            acoustic = acoustic ?? acousticRecognition(samples, using: russian)
            if let heard = acoustic?.text,
               RecognitionNumberMagnitude.hasShorterReading(original: primaryText, acoustic: heard) {
                // Digits alone carry no language evidence. Let the verifier identify
                // the language before using a Russian acoustic reading for this turn.
                let reread = try await generate(language: isRussian ? "Russian" : nil, context: "")
                let confirmedRussian = isRussian || reread.language?.lowercased() == "russian"
                let corrected = confirmedRussian ? RecognitionNumberMagnitude.revisedText(original: primaryText,
                    acoustic: heard, reread: reread.text) : nil
                if let diagnostic {
                    contextDiagnostics.append(["kind": "number-magnitude", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": primaryText, "independent": heard,
                        "reread": reread.text, "candidate": corrected ?? ""])
                }
                if let corrected {
                    primaryText = corrected
                    text = spokenVocabulary.apply(to: corrected)
                }
            }
        }
        if let fillerSpelling {
            // Orthography follows the conversation for these sounds. Decoder
            // disagreement may refine the reading, but cannot make a known
            // acknowledgment an unconfirmed lexical sentence.
            guard BackchannelLanguage.shouldRecheck(text, duration: duration),
                  RussianRecognition.preservesVocabulary(candidate: "", original: text, vocabulary: vocabulary),
                  russian != nil else { return RecognizedSpeech(text: text) }
            let decoded = try await generate(language: nil, context: "")
            guard !BackchannelLanguage.confirmsLatinSource(original: text, reread: decoded.text),
                  let independent = acousticRecognition(samples, using: russian) else { return RecognizedSpeech(text: text) }
            if BackchannelLanguage.confirmsFillerSequence(original: text, reread: decoded.text, corroboration: independent.text) {
                return RecognizedSpeech(text: text, acoustic: independent)
            }
            // Residual microphone noise can produce a filler even when both
            // speech verifiers abstain. Give a quiet reply a second chance
            // with additional audio context before marking it unclear.
            if shortMic, BackchannelLanguage.hasNoSpeechEvidence(language: decoded.language,
                text: decoded.text, corroboration: independent.text) {
                let retry = expandedSamples ?? BackchannelLanguage.retryAudio(samples)
                let checked = try await generate(language: nil, context: "", audioSamples: retry)
                let confirmation = acousticRecognition(retry, using: russian)
                if BackchannelLanguage.hasNoSpeechEvidence(language: checked.language,
                    text: checked.text, corroboration: confirmation?.text) {
                    if let diagnostic {
                        contextDiagnostics.append(["kind": "short-filler-unconfirmed", "start": String(diagnostic.start),
                            "track": diagnostic.track, "source": text])
                    }
                    return RecognizedSpeech(text: "Неразборчиво", independentLanguage: false, acoustic: independent)
                }
            }
            var alternative = decoded.language?.lowercased() == "russian"
                ? BackchannelLanguage.alternative(original: text, russian: spokenVocabulary.apply(to: decoded.text),
                    corroboration: independent.text, vocabulary: vocabulary) : nil
            if alternative == nil, BackchannelLanguage.canVerifyAlternative(original: text, corroboration: independent.text) {
                let checked = try await generate(language: "Russian", context: "")
                alternative = BackchannelLanguage.alternative(original: text, russian: spokenVocabulary.apply(to: checked.text),
                    corroboration: independent.text, vocabulary: vocabulary)
            }
            if let candidate = alternative,
               !BackchannelLanguage.preservesFillerSequenceLength(originalSpelling: fillerSpelling, candidate: candidate) {
                alternative = nil
            }
            if let diagnostic {
                contextDiagnostics.append(["kind": "backchannel-language", "start": String(diagnostic.start),
                    "track": diagnostic.track, "source": text, "reread": decoded.text, "independent": independent.text,
                    "language": decoded.language ?? "", "candidate": alternative ?? ""])
            }
            return RecognizedSpeech(text: text, russianBackchannel: alternative, acoustic: independent)
        }
        if !isMic, BackchannelLanguage.shouldVerifySparseLatinTurn(primaryText, duration: duration) {
            acoustic = acoustic ?? acousticRecognition(samples, using: russian)
            let sourceWordCount = RussianRecognition.words(primaryText).count
            if let heard = acoustic, heard.words.count >= max(8, sourceWordCount * 2),
               let first = heard.words.first, let last = heard.words.last,
               last.start - first.start >= duration * 0.6 {
                let checked = try await generate(language: nil, context: "")
                let candidate = BackchannelLanguage.corroboratedRussianTurn(original: primaryText,
                    language: checked.language, reread: checked.text, corroboration: heard.text, vocabulary: vocabulary)
                if let diagnostic {
                    contextDiagnostics.append(["kind": "sparse-latin-turn", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": primaryText, "reread": checked.text,
                        "independent": heard.text, "language": checked.language ?? "", "candidate": candidate ?? ""])
                }
                if let candidate {
                    return RecognizedSpeech(text: spokenVocabulary.apply(to: candidate), independentLanguage: true, acoustic: heard)
                }
            }
        }
        // Parakeet can turn Russian speech into complete-looking English.
        // First protect independently heard foreign speech, then re-listen
        // with a Russian language preference and no text or vocabulary prompt.
        if let index = BackchannelLanguage.mixedWordIndex(primaryText, duration: duration, vocabulary: vocabulary),
           let heard = acoustic ?? acousticRecognition(samples, using: russian) {
            let reread = try await generate(language: "Russian", context: "")
            let candidate = BackchannelLanguage.restoredMixedWord(primaryText, index: index,
                reread: reread.text, corroboration: heard.text)
            if let diagnostic {
                contextDiagnostics.append(["kind": "mixed-word", "start": String(diagnostic.start),
                    "track": diagnostic.track, "source": primaryText, "reread": reread.text,
                    "independent": heard.text, "candidate": candidate ?? ""])
            }
            if let candidate { return RecognizedSpeech(text: primaryText, russianLexical: candidate, acoustic: heard) }
            if let range = SpeechCoverage.unpaddedShortTurn(start: speechStart, duration: duration, sampleCount: samples.count) {
                let core = Array(samples[range])
                if let isolated = acousticRecognition(core, using: russian) {
                    let checked = try await generate(language: "Russian", context: "", audioSamples: core)
                    let recovered = BackchannelLanguage.restoredMixedWord(primaryText, index: index, reread: checked.text,
                        corroboration: heard.text, isolatedCorroboration: isolated.text)
                    if let diagnostic {
                        contextDiagnostics.append(["kind": "isolated-mixed-word", "start": String(diagnostic.start),
                            "source": primaryText, "reread": checked.text, "independent": isolated.text,
                            "candidate": recovered ?? ""])
                    }
                    if let recovered { return RecognizedSpeech(text: primaryText, russianLexical: recovered, acoustic: heard) }
                }
            }
            if BackchannelLanguage.confirmsOriginalMixedWordContext(original: primaryText, rendered: text,
                    index: index, corroboration: heard.text) {
                text = primaryText
                needsLexicalCheck = BackchannelLanguage.shouldRecheckLexical(text, duration: duration, vocabulary: vocabulary)
            }
        }
        let checkScript = BackchannelLanguage.shouldVerifyShortScript(text, duration: duration, vocabulary: vocabulary)
        if checkScript || needsLexicalCheck {
            let decoded = try await generate(language: nil, context: "")
            if BackchannelLanguage.confirmsCyrillicSource(original: text, reread: decoded.text, language: decoded.language) {
                return RecognizedSpeech(text: text, acoustic: spellingEvidence)
            }
            let words = RussianRecognition.words(text)
            let shortLatinWord = words.count == 1 && words[0].count <= 3 && words[0].utf8.allSatisfy { (97...122).contains($0) }
            // Padding helps the initial decode, but on a short reply it can
            // contribute more sound than the speaker's actual words.
            func unpaddedRussianReading(paddedEvidence: RecognitionAcousticResult? = nil) async throws -> RecognizedSpeech? {
                guard let russian,
                      let range = SpeechCoverage.unpaddedShortTurn(start: speechStart, duration: duration,
                          sampleCount: samples.count, includeAlreadyIsolated: shortLatinWord) else { return nil }
                let sameAudio = range.count == samples.count
                let core = sameAudio ? samples : Array(samples[range])
                let existing = sameAudio ? paddedEvidence : nil
                guard let evidence = existing ?? acousticRecognition(core, using: russian),
                      ParakeetRecognitionPolicy.hasRussianTextEvidence(evidence.text) else { return nil }
                let reread = sameAudio ? decoded : try await generate(language: nil, context: "", audioSamples: core)
                var candidate: String?
                if reread.language?.lowercased() == "russian" {
                    candidate = checkScript ? BackchannelLanguage.agreedRussianText(reread.text, corroboration: evidence.text)
                        : BackchannelLanguage.lexicalAlternative(original: text, russian: reread.text,
                            corroboration: evidence.text, vocabulary: vocabulary)
                }
                if candidate == nil, checkScript, !sameAudio {
                    candidate = BackchannelLanguage.repeatedOnsetAlternative(original: text, padded: decoded.text,
                        language: decoded.language, isolated: reread.text, acoustic: evidence.text)
                }
                var primary: String?
                if candidate == nil, shortLatinWord, RussianRecognition.words(evidence.text).count == 1,
                   !BackchannelLanguage.confirmsLatinSource(original: text, reread: reread.text) {
                    // A single syllable can flip the language label. Ask the
                    // multilingual primary for the same isolated sound. Silence
                    // supplies a word boundary without introducing another voice.
                    func confirms(_ audio: [Float]) -> Bool {
                        primary = measureRecognition("parakeet") { model.generate(audio) }.text
                        return BackchannelLanguage.lexicalAlternative(original: text, russian: evidence.text,
                            corroboration: primary, vocabulary: vocabulary) != nil
                    }
                    let silence = [Float](repeating: 0, count: 2_880)
                    if (!sameAudio && confirms(core)) || confirms(silence + core + silence) { candidate = evidence.text }
                }
                if let diagnostic {
                    contextDiagnostics.append(["kind": "isolated-language", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": text, "independent": evidence.text,
                        "reread": reread.text, "language": reread.language ?? "", "primary": primary ?? "",
                        "candidate": candidate ?? ""])
                }
                guard let candidate else { return nil }
                return RecognizedSpeech(text: text, russianLexical: candidate, acoustic: evidence)
            }
            // Padded models may agree on a foreign reading. Give only a
            // corroborated, unprompted reading of the isolated turn precedence.
            if BackchannelLanguage.confirmsLatinSource(original: text, reread: decoded.text) {
                if let reading = try await unpaddedRussianReading() { return reading }
                if let diagnostic {
                    contextDiagnostics.append(["kind": "confirmed-latin", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": text, "reread": decoded.text])
                }
                return RecognizedSpeech(text: text)
            }
            let independent = acoustic ?? spellingEvidence ?? acousticRecognition(samples, using: russian)
            acoustic = independent
            if checkScript {
                var alternative = BackchannelLanguage.mixedRussianAlternative(original: text, language: decoded.language,
                    reread: decoded.text, corroboration: independent?.text)
                var forced: String?
                if alternative == nil, let heard = independent?.text, ParakeetRecognitionPolicy.hasRussianTextEvidence(heard) {
                    let checked = try await generate(language: "Russian", context: "")
                    forced = checked.text
                    alternative = BackchannelLanguage.corroboratedScriptReread(checked.text, corroboration: heard)
                }
                if let diagnostic {
                    contextDiagnostics.append(["kind": "mixed-language", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": text, "reread": decoded.text, "language": decoded.language ?? "",
                        "russianReread": forced ?? "", "independent": independent?.text ?? "", "candidate": alternative ?? ""])
                }
                if alternative == nil, let reading = try await unpaddedRussianReading(paddedEvidence: independent) { return reading }
                return RecognizedSpeech(text: text, russianLexical: alternative, independentLanguage: false, acoustic: independent)
            }
            var alternative = decoded.language?.lowercased() == "russian"
                ? BackchannelLanguage.lexicalAlternative(original: text,
                    russian: spokenVocabulary.apply(to: decoded.text),
                    corroboration: independent?.text, vocabulary: vocabulary) : nil
            var russianReread: String?
            if alternative == nil, !BackchannelLanguage.isBriefCyrillicSource(text, vocabulary: vocabulary),
               let heard = independent?.text, ParakeetRecognitionPolicy.hasRussianTextEvidence(heard) {
                let checked = try await generate(language: "Russian", context: "")
                russianReread = checked.text
                alternative = BackchannelLanguage.russianRereadAlternative(original: text,
                    russian: spokenVocabulary.apply(to: checked.text), corroboration: heard, vocabulary: vocabulary)
            }
            if let diagnostic {
                contextDiagnostics.append(["kind": "short-language", "start": String(diagnostic.start),
                    "track": diagnostic.track, "source": text, "reread": decoded.text,
                    "language": decoded.language ?? "", "independent": independent?.text ?? "",
                    "russianReread": russianReread ?? "", "candidate": alternative ?? ""])
            }
            if let alternative {
                return RecognizedSpeech(text: text, russianLexical: alternative, acoustic: independent)
            }
            if let reading = try await unpaddedRussianReading(paddedEvidence: independent) { return reading }
            if BackchannelLanguage.isBriefCyrillicSource(text, vocabulary: vocabulary) {
                return RecognizedSpeech(text: text, acoustic: independent)
            }
            // Keep a disputed Latin reading tentative until conversation
            // context is available. Use padded microphone audio when both
            // models abstain to give faint overlapping replies another chance.
            // A valid empty GigaAM result is evidence. If the optional model
            // is unavailable, a multilingual decoder explicitly hearing a
            // different language is still a reason to question a whole clause.
            let otherLanguage = decoded.language.map { $0.lowercased() != "english" } ?? false
            uncertainLanguage = independent != nil || (otherLanguage && RussianRecognition.words(text).count >= 2)
            if isMic, BackchannelLanguage.hasNoSpeechEvidence(language: decoded.language,
                text: decoded.text, corroboration: independent?.text) {
                let retry = expandedSamples ?? BackchannelLanguage.retryAudio(samples)
                let checked = try await generate(language: nil, context: "", audioSamples: retry)
                let confirmation = acousticRecognition(retry, using: russian)
                if BackchannelLanguage.confirmsLatinSource(original: text, reread: checked.text) {
                    return RecognizedSpeech(text: text, acoustic: confirmation)
                }
                if checked.language?.lowercased() == "russian",
                   let alternative = BackchannelLanguage.lexicalAlternative(original: text,
                       russian: spokenVocabulary.apply(to: checked.text), corroboration: confirmation?.text, vocabulary: vocabulary) {
                    return RecognizedSpeech(text: text, russianLexical: alternative, acoustic: confirmation)
                }
                if BackchannelLanguage.hasNoSpeechEvidence(language: checked.language,
                    text: checked.text, corroboration: confirmation?.text) {
                    if let diagnostic {
                        contextDiagnostics.append(["kind": "short-unconfirmed", "start": String(diagnostic.start),
                            "track": diagnostic.track, "source": text])
                    }
                    return RecognizedSpeech(text: text, uncertainLanguage: true, acoustic: independent)
                }
            }
        }
        if BackchannelLanguage.shouldRecheck(text, duration: duration) {
            acoustic = acoustic ?? acousticRecognition(samples, using: russian)
            var alternative: String?
            if BackchannelLanguage.canVerifyAlternative(original: text, corroboration: acoustic?.text) {
                let decoded = try await generate(language: "Russian", context: "")
                alternative = BackchannelLanguage.alternative(original: text, russian: spokenVocabulary.apply(to: decoded.text),
                    corroboration: acoustic?.text, vocabulary: vocabulary)
            }
            if alternative == nil, let russian {
                let retry = BackchannelLanguage.retryAudio(samples)
                let independent = acousticRecognition(retry, using: russian)?.text
                if let independent, BackchannelLanguage.canVerifyAlternative(original: text, corroboration: independent) {
                    let checked = try await generate(language: "Russian", context: "", audioSamples: retry)
                    alternative = BackchannelLanguage.alternative(original: text, russian: spokenVocabulary.apply(to: checked.text),
                        corroboration: independent, vocabulary: vocabulary)
                }
            }
            return RecognizedSpeech(text: text, russianBackchannel: alternative, uncertainLanguage: uncertainLanguage,
                independentLanguage: unverifiedLanguage, acoustic: acoustic)
        }
        // Diarization can leave a complete lexical reply shorter than two
        // seconds, or clip its last syllable during an overlapping next turn.
        // Verify such replies with independent audio evidence, never a sentence
        // copied into the prompt. Expanded sound is accepted only on agreement.
        let shortRussian = isRussian && (0.35..<2).contains(duration)
            && (2...6).contains(RussianRecognition.words(text).count)
        if shortRussian || (isRussian && duration >= 2) {
            acoustic = acoustic ?? acousticRecognition(samples, using: russian)
            if duration <= 30, let heard = acoustic?.text,
               let repair = RussianRecognition.embeddedLatinRepair(original: text, heard: heard, vocabulary: vocabulary) {
                // Cross-check the actual turn without neighboring voices or a
                // Russian prompt that might translate a genuine code switch.
                let core = SpeechCoverage.unpaddedTurn(start: speechStart, duration: duration, sampleCount: samples.count)
                let checked = try await generate(language: nil, context: "", audioSamples: core.map { Array(samples[$0]) })
                let confirmed = repair.confirmedText(language: checked.language, reread: checked.text)
                if let diagnostic {
                    contextDiagnostics.append(["kind": "embedded-latin", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": text, "independent": heard, "reread": checked.text,
                        "language": checked.language ?? "", "candidate": confirmed ?? ""])
                }
                return RecognizedSpeech(text: confirmed ?? text, acoustic: acoustic)
            }
            if let heard = acoustic?.text,
               let repair = RussianRecognition.sharedAlphabetSpelling(original: primaryText, heard: heard, vocabulary: vocabulary) {
                performanceDiagnostics?["qwenSharedAlphabetChecks", default: 0] += 1
                let checked = try await generate(language: nil, context: "")
                let confirmed = repair.confirmedText(language: checked.language, reread: checked.text)
                if confirmed != nil { performanceDiagnostics?["qwenSharedAlphabetAccepted", default: 0] += 1 }
                if let diagnostic {
                    contextDiagnostics.append(["kind": "shared-alphabet-spelling", "start": String(diagnostic.start),
                        "track": diagnostic.track, "source": primaryText, "independent": heard, "reread": checked.text,
                        "language": checked.language ?? "", "candidate": confirmed ?? ""])
                }
                // A forced or prompted reread cannot resolve a disagreement
                // about the language of this same word.
                return RecognizedSpeech(text: confirmed.map { spokenVocabulary.apply(to: $0) } ?? text, acoustic: acoustic)
            }
        }
        if shortRussian, let russian, let independent = acoustic?.text,
           RussianRecognition.words(independent) != RussianRecognition.words(text) {
            if let evidence = acoustic, let core = SpeechCoverage.unpaddedShortTurn(start: speechStart,
                duration: duration, sampleCount: samples.count),
               let fragment = RecognitionTrailingFragment(source: text, acoustic: evidence, core: core, sampleCount: samples.count),
               RussianRecognition.preservesVocabulary(candidate: fragment.prefix, original: text, vocabulary: vocabulary) {
                let exact = Array(samples[core])
                let coreReading = acousticRecognition(exact, using: russian)
                // Change only the right edge to verify that the neighboring
                // word disappeared because its audio was actually removed.
                let leftReading = core.lowerBound == 0 ? coreReading
                    : acousticRecognition(Array(samples[..<core.upperBound]), using: russian)
                if fragment.matchesCore(coreReading?.text), fragment.matchesCore(leftReading?.text) {
                    let padded = try await generate(language: nil, context: "")
                    let reread = try await generate(language: nil, context: "", audioSamples: exact)
                    if let verified = fragment.confirmedText(padded: padded.text, paddedLanguage: padded.language,
                                                            exact: reread.text, exactLanguage: reread.language) {
                        if let diagnostic {
                            contextDiagnostics.append(["kind": "trailing-fragment", "start": String(diagnostic.start),
                                "track": diagnostic.track, "source": text, "padded": padded.text, "reread": reread.text,
                                "independent": independent, "core": coreReading?.text ?? "", "candidate": verified])
                        }
                        return RecognizedSpeech(text: verified, acoustic: acoustic)
                    }
                }
            }
            let hints = spokenVocabulary.relevantTerms(in: [text, independent])
            if !hints.isEmpty {
                let checked = try await generate(language: "Russian", context: hints, promptVocabulary: hints)
                let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let revised = RecognitionConsensus.revisedText(original: text, candidate: candidate,
                    corroboration: independent, vocabulary: vocabulary, allowShortTurn: true) {
                    return RecognizedSpeech(text: revised)
                }
            }
            if let expandedSamples, let independent = acousticRecognition(expandedSamples, using: russian)?.text {
                let checked = try await generate(language: "Russian", context: "", audioSamples: expandedSamples)
                let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
                if let revised = RecognitionConsensus.revisedText(original: text, candidate: candidate,
                    corroboration: independent, vocabulary: vocabulary, allowShortTurn: true, expandedAudio: true) {
                    return RecognizedSpeech(text: revised)
                }
            }
        }
        if isRussian, duration >= 2, let rawResult = acoustic {
            let rawHypothesis = rawResult.text
            let (hypothesis, usesCyrillicHints) = spokenVocabulary.promptResult(rawHypothesis)
            if RussianRecognition.shouldRecheck(language: isRussian ? "Russian" : nil, duration: duration, original: text, alternative: hypothesis) {
                try Task.checkCancellation()
                let canonical = spokenVocabulary.apply(to: rawHypothesis)
                if RussianRecognition.canRevise(original: text, corroboration: rawHypothesis, hypothesis: hypothesis,
                                                 vocabulary: vocabulary, dictionaryCorroboration: canonical) {
                    let checked = try await generate(language: nil, context: RussianRecognition.context(vocabulary: context, hypothesis: hypothesis))
                    let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if checked.language?.lowercased() == "russian",
                       let revised = RussianRecognition.revisedText(original: text, candidate: candidate,
                            corroboration: rawHypothesis, hypothesis: hypothesis, vocabulary: vocabulary,
                            usesCyrillicHints: usesCyrillicHints, dictionaryCorroboration: canonical,
                            rawCandidate: checked.text) {
                        text = revised
                    }
                } else {
                    performanceDiagnostics?["qwenSkippedUnrepairable", default: 0] += 1
                }
                // Different acoustic boundaries can make the broad hypothesis
                // distract from a name. Retry only a still-missing explicit
                // name heard by the verifier; keep successful repairs intact.
                if let focusedName = spokenVocabulary.focusedNameHypothesis(original: text, corroboration: rawHypothesis) {
                    try Task.checkCancellation()
                    let focused = try await generate(language: nil, context: RussianRecognition.context(vocabulary: context, hypothesis: focusedName))
                    let candidate = spokenVocabulary.apply(to: focused.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    if focused.language?.lowercased() == "russian",
                       let revised = RussianRecognition.revisedText(original: text, candidate: candidate,
                            corroboration: rawHypothesis, hypothesis: focusedName, vocabulary: vocabulary, usesCyrillicHints: false,
                            dictionaryCorroboration: spokenVocabulary.apply(to: rawHypothesis), rawCandidate: focused.text),
                       spokenVocabulary.focusedNameHypothesis(original: revised, corroboration: rawHypothesis) == nil {
                        text = revised
                    }
                }
            }
        }
        // An intact letter stem and a spoken ending can survive even when a
        // fused numeral is misspelled. Use that spelling only as an audio hint;
        // accept the same form only at matching, unique neighboring words.
        if isRussian,
           let numericContext = spokenVocabulary.numericRepairContext(in: text) {
            let checked = try await generate(language: "Russian", context: numericContext, promptVocabulary: numericContext)
            if let revised = spokenVocabulary.restoringNumericName(original: text, candidate: checked.text) {
                text = revised
            }
        }
        // A base-only glossary can bias an otherwise correct numeric name
        // towards losing its spoken case ending. Re-decode only an observed
        // numeric name with alternative spellings, then keep just the locally
        // anchored ending. Unrelated speech never receives these extra hints.
        if isRussian,
           spokenVocabulary.needsNumericEndingCheck(in: text) {
            let checked = try await generate(language: "Russian", context: decodingVocabulary,
                promptVocabulary: decodingVocabulary)
            let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let revised = RussianRecognition.restoringNumericEndings(original: text, candidate: candidate, vocabulary: vocabulary) {
                text = revised
            }
        }
        if isRussian, duration >= 2, let acoustic,
           let hint = spokenVocabulary.technologyRereadHint(in: text) {
            let checked = try await generate(language: "Russian", context: hint.term, promptVocabulary: hint.term)
            let candidate = spokenVocabulary.apply(to: checked.text.trimmingCharacters(in: .whitespacesAndNewlines))
            if let revised = RecognitionContext.revisedTechnicalTerm(original: text, candidate: candidate,
                corroboration: spokenVocabulary.apply(to: acoustic.text), term: hint.term,
                sourceRange: hint.range, vocabulary: vocabulary) {
                text = revised
            }
        }
        return RecognizedSpeech(text: text, uncertainLanguage: uncertainLanguage, independentLanguage: unverifiedLanguage, acoustic: acoustic)
        } catch is ParakeetRecognitionSession.VerifierUnavailable {
            return RecognizedSpeech(text: text, uncertainLanguage: uncertainLanguage, independentLanguage: unverifiedLanguage, acoustic: acoustic)
        }
    }
}
