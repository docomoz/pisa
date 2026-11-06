import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

/// An opt-in benchmark of supplied 16 kHz fixtures. Only reads model preferences;
/// all audio is temporary and no meeting or voice profile is created or changed.
enum RecognitionQualityTests {
    private struct Fixture: Decodable {
        var name: String
        var samples: [Float]
        var context: String?
        var track: String?
        var live: Bool?
    }
    private struct Request: Decodable {
        var fixtures: [Fixture]
        var modes: [String]
        var russianVerification: Bool?
    }

    @MainActor static func run() async throws {
        let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let modes = Set(["pipeline", "acoustic", "auto", "russian", "unpenalized", "russian-unpenalized"])
        guard !request.fixtures.isEmpty, request.modes.allSatisfy(modes.contains),
              request.fixtures.allSatisfy({ !$0.samples.isEmpty && $0.samples.count <= 16000 * 120 && $0.samples.allSatisfy(\.isFinite) }),
              !request.modes.contains("acoustic") || request.fixtures.allSatisfy({ $0.samples.count <= 16000 * 30 }) else {
            throw PisyaError.message("Invalid recognition fixtures or modes")
        }
        let userRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisya")
        let preferencesURL = userRoot.appendingPathComponent("preferences.json")
        let preferences = FileManager.default.fileExists(atPath: preferencesURL.path)
            ? try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL)) : Preferences()
        let directory: URL
        if let bookmark = preferences.modelBookmark {
            var stale = false
            directory = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        } else { directory = userRoot.appendingPathComponent("Models/Qwen3-ASR") }
        let granted = directory.startAccessingSecurityScopedResource()
        defer { if granted { directory.stopAccessingSecurityScopedResource() } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-recognition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = Transcriber()
        do {
            if request.modes.contains("pipeline") {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                for fixture in request.fixtures {
                    let live = fixture.live ?? true
                    if !live { await transcriber.finishLive() }
                    let track = fixture.track == "remote" ? "remote" : "mic"
                    let url = root.appendingPathComponent("fixture-\(track).caf")
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fixture.samples.count))!
                    buffer.frameLength = AVAudioFrameCount(fixture.samples.count)
                    fixture.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                    let writer = try AVAudioFile(forWriting: url, settings: format.settings)
                    try writer.write(from: buffer); writer.close()
                    let began = Date()
                    let segments = try await transcriber.transcribe(files: [(url, 0)], modelDirectory: directory,
                        context: fixture.context ?? "", speakerDirectory: userRoot.appendingPathComponent("Models/Speakers"),
                        profiles: [], quiet: false, live: live, russianVerification: request.russianVerification ?? true) { _, _ in }
                    var extra: [String: Any] = ["live": live,
                        "segments": segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }]
                    if live { extra["russianVerifierLoaded"] = await transcriber.liveRussianModelIdentity() != nil }
                    try emit(name: fixture.name, mode: "pipeline", text: segments.map(\.text).joined(separator: " "),
                             seconds: Date().timeIntervalSince(began), extra: extra)
                }
            }
            await transcriber.finishLive()
        } catch {
            await transcriber.finishLive()
            throw error
        }
        if request.modes.contains("acoustic") {
            let russian = try RussianSpeechRecognizer(directory: userRoot.appendingPathComponent("Models/" + RussianSpeechRecognizer.directoryName))
            let pronunciations = Bundle.main.url(forResource: "cmudict", withExtension: "dict")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            for fixture in request.fixtures {
                let began = Date()
                let text = russian.recognize(fixture.samples) ?? ""
                let vocabulary = SpokenVocabulary(fixture.context ?? "", pronunciations: pronunciations)
                try emit(name: fixture.name, mode: "acoustic", text: text, seconds: Date().timeIntervalSince(began),
                         extra: ["promptHypothesis": vocabulary.promptHypothesis(text)])
            }
        }
        let rawModes = request.modes.filter { $0 != "pipeline" && $0 != "acoustic" }
        if !rawModes.isEmpty {
            let previousLimit = Memory.cacheLimit
            Memory.cacheLimit = 256 * 1024 * 1024
            defer { Memory.clearCache(); Memory.cacheLimit = previousLimit }
            let model = try await Qwen3ASRModel.fromModelDirectory(directory)
            for fixture in request.fixtures {
                let duration = Double(fixture.samples.count) / 16000
                for mode in rawModes {
                    let began = Date()
                    let result = model.generate(audio: MLXArray(fixture.samples), maxTokens: min(2048, max(128, Int(duration * 24))),
                        context: fixture.context ?? "", language: mode.hasPrefix("russian") ? "Russian" : nil,
                        chunkDuration: 120, repetitionPenalty: mode.contains("unpenalized") ? 1 : 1.1)
                    try emit(name: fixture.name, mode: mode, text: result.text, seconds: Date().timeIntervalSince(began),
                             extra: ["language": result.language ?? "", "tokens": result.generationTokens])
                }
            }
        }
        print("RECOGNITION_QUALITY_OK")
    }

    private static func emit(name: String, mode: String, text: String, seconds: Double, extra: [String: Any]) throws {
        var result = extra
        result.merge(["name": name, "mode": mode, "text": text, "seconds": seconds]) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
