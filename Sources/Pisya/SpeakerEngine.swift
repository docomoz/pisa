import Foundation

struct VoiceRegion { var start: Double; var end: Double; var embedding: [Float]? }
final class SpeakerEngine {
    private var diarizer: OpaquePointer?
    private var extractor: OpaquePointer?
    init(directory: URL) throws {
        let segmentation = directory.appendingPathComponent("segmentation.onnx").path
        let embedding = directory.appendingPathComponent("titanet.onnx").path
        guard FileManager.default.fileExists(atPath: segmentation), FileManager.default.fileExists(atPath: embedding) else { throw PisyaError.message("Не найдены модели разметки голосов") }
        segmentation.withCString { segmentation in embedding.withCString { embedding in "cpu".withCString { cpu in
            var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
            config.segmentation.pyannote.model = segmentation
            config.segmentation.num_threads = 2; config.segmentation.provider = cpu
            config.embedding.model = embedding; config.embedding.num_threads = 2; config.embedding.provider = cpu
            config.clustering.num_clusters = -1; config.clustering.threshold = 0.65
            config.min_duration_on = 0.5; config.min_duration_off = 0.3
            diarizer = SherpaOnnxCreateOfflineSpeakerDiarization(&config)
            extractor = SherpaOnnxCreateSpeakerEmbeddingExtractor(&config.embedding)
        } } }
        guard diarizer != nil, extractor != nil else { throw PisyaError.message("Не удалось загрузить модели голосов") }
    }
    deinit { if let diarizer { SherpaOnnxDestroyOfflineSpeakerDiarization(diarizer) }; if let extractor { SherpaOnnxDestroySpeakerEmbeddingExtractor(extractor) } }
    func regions(_ samples: [Float]) -> [VoiceRegion] {
        guard let diarizer, samples.count >= 16000,
              let result = SherpaOnnxOfflineSpeakerDiarizationProcess(diarizer, samples, Int32(samples.count)) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let count = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard count > 0, let sorted = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(sorted) }
        // Sherpa's local speaker IDs group turns within this window. Reuse one
        // embedding built from several turns, instead of a noisy vector per fragment.
        var audioBySpeaker: [Int32: [Float]] = [:]
        for index in 0..<count {
            let s = sorted[index]
            let lower = max(0, Int(s.start * 16000)), upper = min(samples.count, Int(s.end * 16000))
            guard upper > lower else { continue }
            let capacity = max(0, 16000 * 12 - (audioBySpeaker[s.speaker]?.count ?? 0))
            if capacity > 0 { audioBySpeaker[s.speaker, default: []].append(contentsOf: samples[lower..<min(upper, lower + capacity)]) }
        }
        let vectors = audioBySpeaker.mapValues { vector($0) }
        var regions: [VoiceRegion] = []
        for index in 0..<count {
            let s = sorted[index]
            let start = max(0, Int(s.start * 16000)); let end = min(samples.count, Int(s.end * 16000))
            guard end - start >= 8000 else { continue }
            regions.append(VoiceRegion(start: Double(start) / 16000, end: Double(end) / 16000, embedding: vectors[s.speaker] ?? nil))
        }
        return regions
    }
    func vector(_ samples: [Float]) -> [Float]? {
        guard let extractor, samples.count >= 24000, let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(extractor) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, Int32(samples.count))
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(extractor, stream) != 0,
              let vector = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(extractor, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(vector) }
        return Array(UnsafeBufferPointer(start: vector, count: Int(SherpaOnnxSpeakerEmbeddingExtractorDim(extractor))))
    }
}
