import Foundation

struct VoiceRegion {
    var start: Double
    var end: Double
    var embedding: [Float]?
    var recoveredSpeech = false
    var embeddingExclusions: [Range<Int>] = []
}
final class SpeakerEngine {
    private var diarizer: OpaquePointer?
    private let extractor: SpeakerEmbeddingExtractor

    init(directory: URL) throws {
        let segmentation = directory.appendingPathComponent("segmentation.onnx").path
        let embedding = directory.appendingPathComponent("titanet.onnx")
        guard FileManager.default.fileExists(atPath: segmentation) else { throw PisyaError.message("Не найдены модели разметки голосов") }
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
        guard diarizer != nil else { throw PisyaError.message("Не удалось загрузить модели голосов") }
    }

    deinit { if let diarizer { SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer) } }

    func regions(_ samples: [Float]) -> [VoiceRegion] {
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
            return VoiceRegion(start: Double(turn.range.lowerBound) / Double(sampleRate),
                end: Double(turn.range.upperBound) / Double(sampleRate),
                embedding: vector(samples, in: turn.range, excluding: overlaps),
                embeddingExclusions: overlaps)
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
        let minimum = SpeakerEmbeddingExtractor.minimumSamples
        guard range.count >= minimum else { return nil }
        let clean = SpeechCoverage.uncovered(speech: [range], covered: overlaps,
            sampleCount: samples.count, minimumPartialLength: minimum)
        guard let longest = clean.max(by: { $0.count < $1.count }), longest.count >= minimum else { return nil }
        let length = min(SpeakerEmbeddingExtractor.sampleRate * 12, longest.count)
        let lower = longest.lowerBound + (longest.count - length) / 2
        return vector(Array(samples[lower..<(lower + length)]))
    }

    func vector(_ samples: [Float]) -> [Float]? {
        extractor.vector(samples)
    }
}

final class SpeakerEmbeddingExtractor {
    static let sampleRate = 16000
    static let minimumSamples = 24000
    private let extractor: OpaquePointer

    init(model: URL) throws {
        guard FileManager.default.fileExists(atPath: model.path) else { throw PisyaError.message("Не найдены модели разметки голосов") }
        let extractor = model.path.withCString { path in
            "cpu".withCString { cpu in
                var config = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                config.model = path
                config.num_threads = 2
                config.provider = cpu
                return SherpaOnnxCreateSpeakerEmbeddingExtractor(&config)
            }
        }
        guard let extractor else { throw PisyaError.message("Не удалось загрузить модели голосов") }
        self.extractor = extractor
    }

    deinit { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) }

    func vector(_ samples: [Float]) -> [Float]? {
        guard samples.count >= Self.minimumSamples,
              let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(Self.sampleRate), samples, Int32(samples.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))))
    }
}
