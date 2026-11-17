import Foundation

/// An in-progress batch is separate from the meeting's last finished transcript.
final class BatchTranscriptionCheckpoint: Codable {
    struct Inputs: Codable, Equatable {
        struct FileStamp: Codable, Equatable {
            var size: Int?
            var modifiedAt: Date?

            init(_ url: URL) throws {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                size = (attributes[.size] as? NSNumber)?.intValue
                modifiedAt = attributes[.modificationDate] as? Date
            }
        }

        struct Track: Codable, Equatable {
            var name: String
            var offset: Double
            var stamp: FileStamp
        }

        var tracks: [Track]
        var modelPath: String
        var build: String
        var modelFiles: [String: FileStamp]
        var vocabulary: String
        var variants: [String: [String]]

        init(files: [(URL, Double)], model: URL, vocabulary: String, variants: [String: [String]],
             build: String = "", supportingModels: [URL] = []) throws {
            tracks = try files.map { url, offset in
                Track(name: url.lastPathComponent, offset: offset, stamp: try FileStamp(url))
            }
            modelPath = model.standardizedFileURL.path
            self.build = build
            modelFiles = [:]
            let files = ["model.safetensors", "config.json", "tokenizer_config.json", "tokenizer.json", "vocab.json", "merges.txt"]
                .map { model.appendingPathComponent($0) }
            for url in files + supportingModels {
                modelFiles[url.path] = try? FileStamp(url)
            }
            self.vocabulary = vocabulary
            self.variants = variants
        }
    }

    final class FirstPass: Codable {
        struct RecoveredAudio: Codable {
            var gap: Range<Double>
            var evidence: Range<Double>
        }

        var segments: [TranscriptSegment] = []
        var backchannels: [UUID: String] = [:]
        var lexicalBackchannels: [UUID: String] = [:]
        var uncertainShortLanguage: Set<UUID> = []
        var hypotheses: [UUID: RecognitionAcousticResult] = [:]
        var bounds: [UUID: Range<Double>] = [:]
        var recoveredAudio: [UUID: RecoveredAudio] = [:]

        private enum CodingKeys: String, CodingKey {
            case segments, backchannels, lexicalBackchannels, uncertainShortLanguage, hypotheses, bounds, recoveredAudio
        }

        init() {}

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            segments = try container.decode([TranscriptSegment].self, forKey: .segments)
            backchannels = try container.decode([UUID: String].self, forKey: .backchannels)
            lexicalBackchannels = try container.decodeIfPresent([UUID: String].self, forKey: .lexicalBackchannels) ?? [:]
            uncertainShortLanguage = try container.decodeIfPresent(Set<UUID>.self, forKey: .uncertainShortLanguage) ?? []
            hypotheses = try container.decode([UUID: RecognitionAcousticResult].self, forKey: .hypotheses)
            bounds = try container.decode([UUID: Range<Double>].self, forKey: .bounds)
            recoveredAudio = try container.decode([UUID: RecoveredAudio].self, forKey: .recoveredAudio)
        }
    }

    let inputs: Inputs
    var recognition = FirstPass()
    var rangesCompleted: [String: Int] = [:]
    var completedTracks: Set<String> = []
    var processedMicrophone: String?
    var firstPassComplete = false
    var progress: Double = 0
    private(set) var revisionCount = 0
    private(set) var revisions: [UUID: String] = [:]
    private var lastSaved: ContinuousClock.Instant?

    private enum CodingKeys: String, CodingKey {
        case inputs, recognition, rangesCompleted, completedTracks, processedMicrophone
        case firstPassComplete, progress, revisionCount, revisions
    }

    init(inputs: Inputs) { self.inputs = inputs }

    func trimUncommittedSegments(after count: Int) {
        for segment in recognition.segments.dropFirst(count) {
            recognition.backchannels[segment.id] = nil
            recognition.lexicalBackchannels[segment.id] = nil
            recognition.uncertainShortLanguage.remove(segment.id)
            recognition.hypotheses[segment.id] = nil
            recognition.bounds[segment.id] = nil
            recognition.recoveredAudio[segment.id] = nil
        }
        recognition.segments.removeLast(recognition.segments.count - count)
    }

    func recordRevision(index: Int, segment: TranscriptSegment, text: String, progress: Double) {
        if text != segment.text { revisions[segment.id] = text }
        revisionCount = index + 1
        self.progress = progress
    }

    static func load(from url: URL) throws -> BatchTranscriptionCheckpoint? {
        do {
            let data = try Data(contentsOf: url)
            return try PropertyListDecoder().decode(Self.self, from: data)
        } catch is DecodingError {
            return nil // An incompatible or damaged checkpoint can be recreated from audio.
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(to url: URL, force: Bool = true) throws {
        let now = ContinuousClock.now
        if !force, let lastSaved, now - lastSaved < .seconds(3) { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(self).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        lastSaved = now
    }
}
