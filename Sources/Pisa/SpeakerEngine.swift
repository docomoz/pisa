import Foundation

struct VoiceRegion {
    var start: Double
    var end: Double
    var embedding: [Float]?
    var embeddingDuration: Double? = nil
    var speakerEvidenceIsMixed: Bool? = nil
    var recoveredSpeech = false
    var embeddingExclusions: [Range<Int>] = []
    // Keep integer bounds independently of displayed/recognition timestamps.
    var embeddingRange: Range<Int>? = nil
}
final class SpeakerEngine {
    private var diarizer: OpaquePointer?
    private let extractor: SpeakerEmbeddingExtractor

    init(directory: URL) throws {
        let segmentation = directory.appendingPathComponent("segmentation.onnx").path
        let embedding = directory.appendingPathComponent("titanet.onnx")
        guard FileManager.default.fileExists(atPath: segmentation) else { throw PisaError.message("Не найдены модели разметки голосов") }
        extractor = try SpeakerEmbeddingExtractor(model: embedding)
        diarizer = segmentation.withCString { segmentation in
            embedding.path.withCString { embedding in
                "cpu".withCString { cpu in
                    var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
                    config.segmentation.pyannote.model = segmentation
                    config.segmentation.num_threads = 2
                    config.segmentation.provider = cpu
                    config.embedding.model = embedding
                    config.embedding.num_threads = 2
                    config.embedding.provider = cpu
                    config.clustering.num_clusters = -1
                    config.clustering.threshold = 0.65
                    config.min_duration_on = 0.5
                    config.min_duration_off = 0.3
                    return SherpaOnnxCreateOfflineSpeakerDiarization(&config)
                }
            }
        }
        guard diarizer != nil else { throw PisaError.message("Не удалось загрузить модели голосов") }
    }

    deinit { if let diarizer { SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer) } }

    func regions(_ samples: [Float], extractEmbeddings: Bool = true) -> [VoiceRegion] {
        let sampleRate = SpeakerEmbeddingExtractor.sampleRate
        guard let diarizer, samples.count >= sampleRate,
              let result = SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, samples, Int32(samples.count)) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0, let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
        let turns: [(range: Range<Int>, speaker: Int32)] = (0..<count).compactMap { index in
            let segment = sorted[index]
            let lower = max(0, Int(segment.start * Float(sampleRate)))
            let upper = min(samples.count, Int(segment.end * Float(sampleRate)))
            guard upper > lower else { return nil }
            return (lower..<upper, segment.speaker)
        }
        return turns.compactMap { turn in
            guard turn.range.count >= sampleRate / 2 else { return nil }
            // Local speaker IDs can contain different voices. Extract evidence
            // from this turn alone and exclude audio shared with another ID.
            let overlaps = turns.prefix { $0.range.lowerBound < turn.range.upperBound }
                .filter { $0.speaker != turn.speaker && $0.range.overlaps(turn.range) }
                .map(\.range)
            let evidence = extractEmbeddings ? embedding(samples, in: turn.range, excluding: overlaps) : nil
            let mixed: Bool? = extractEmbeddings ? SpeakerEmbeddingInput(range: turn.range, exclusions: overlaps)
                .hasSustainedOverlap(sampleCount: samples.count, sampleRate: sampleRate) : nil
            return VoiceRegion(start: Double(turn.range.lowerBound) / Double(sampleRate),
                end: Double(turn.range.upperBound) / Double(sampleRate),
                embedding: evidence?.vector, embeddingDuration: evidence?.duration,
                speakerEvidenceIsMixed: mixed,
                embeddingExclusions: overlaps, embeddingRange: turn.range)
        }
    }

    /// Missing segmentation is not evidence of multiple voices. Only positive,
    /// sustained competing activity excludes an otherwise extractable sample.
    func hasConflictingSpeakerActivity(_ samples: [Float]) -> Bool {
        guard let diarizer, samples.count >= 16000,
              let result = SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, samples, Int32(samples.count)) else { return false }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0, let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return false }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
        let duration = Double(samples.count) / 16000
        let activity = (0..<count).map { index in
            (speaker: Int(sorted[index].speaker), start: max(0, Double(sorted[index].start)), end: min(duration, Double(sorted[index].end)))
        }
        return SpeakerSampleQuality.hasSustainedConflict(activity)
    }

    func vector(_ samples: [Float], in range: Range<Int>, excluding overlaps: [Range<Int>]) -> [Float]? {
        embedding(samples, in: range, excluding: overlaps)?.vector
    }

    func embedding(_ samples: [Float], in range: Range<Int>, excluding overlaps: [Range<Int>]) -> (vector: [Float], duration: Double)? {
        let sampleRate = SpeakerEmbeddingExtractor.sampleRate
        let input = SpeakerEmbeddingInput(range: range, exclusions: overlaps)
        guard let excerpt = input.cleanRange(sampleCount: samples.count,
            minimumSamples: SpeakerEmbeddingExtractor.minimumSamples, maximumSamples: sampleRate * 12),
            let vector = vector(Array(samples[excerpt])) else { return nil }
        return (vector, Double(excerpt.count) / Double(sampleRate))
    }

    func vector(_ samples: [Float]) -> [Float]? {
        extractor.vector(samples)
    }
}

struct SpeakerEmbeddingMetrics {
    var attemptedCalls = 0
    var successfulCalls = 0
    var inferenceSeconds: Double = 0
}

final class SpeakerEmbeddingExtractor {
    private static let metricsLock = NSLock()
    private static var metrics = SpeakerEmbeddingMetrics()

    static var inferenceMetrics: SpeakerEmbeddingMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return metrics
    }

    static func resetInferenceMetrics() {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        metrics = SpeakerEmbeddingMetrics()
    }

    private static func recordInference(succeeded: Bool, seconds: Double) {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        metrics.attemptedCalls += 1
        if succeeded { metrics.successfulCalls += 1 }
        metrics.inferenceSeconds += seconds
    }

    static let sampleRate = 16000
    static let minimumSamples = 24000
    private let extractor: OpaquePointer

    init(model: URL) throws {
        guard FileManager.default.fileExists(atPath: model.path) else { throw PisaError.message("Не найдены модели разметки голосов") }
        let extractor = model.path.withCString { path in
            "cpu".withCString { cpu in
                var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                config.model = path
                config.num_threads = 2
                config.provider = cpu
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
            }
        }
        guard let extractor else { throw PisaError.message("Не удалось загрузить модели голосов") }
        self.extractor = extractor
    }

    deinit { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }

    func vector(_ samples: [Float]) -> [Float]? {
        guard samples.count >= Self.minimumSamples,
              let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(Self.sampleRate), samples, Int32(samples.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0 else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        let computed = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream)
        Self.recordInference(succeeded: computed != nil, seconds: ProcessInfo.processInfo.systemUptime - started)
        guard let vector = computed else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))))
    }
}
