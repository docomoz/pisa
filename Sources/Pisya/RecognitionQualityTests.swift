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
        var referenceSamples: [Float]?
        var contextGroup: String?
        var timelineStart: Double?
    }
    private struct Request: Decodable {
        var fixtures: [Fixture]
        var modes: [String]
        var russianVerification: Bool?
        var contextualVerification: Bool?
        var diagnostics: Bool?
    }

    private struct ReplayEnvelope: Decodable {
        let replay: Replay
    }
    private struct Replay: Decodable {
        struct Interval: Decodable {
            let start: Double
            let end: Double
        }
        let meeting: Meeting
        let vocabulary: String
        let audioDirectory: String?
        let targets: [UUID]
        let fileLocalBounds: [String: Interval]?
        let repeatFirstPass: Bool?
    }

    @MainActor private static func replay(_ request: Replay, root: URL, modelDirectory: URL) async throws {
        let began = Date()
        let meeting = request.meeting
        let targetIDs = Set(request.targets)
        let names = Set(meeting.segments.compactMap(\.audioFile))
        let audio = request.audioDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("Audio", isDirectory: true)
        guard !targetIDs.isEmpty, targetIDs.count <= 20,
              targetIDs.isSubset(of: Set(meeting.segments.map(\.id))),
              meeting.segments.filter({ targetIDs.contains($0.id) }).allSatisfy({ $0.audioFile != nil }),
              names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("..") }) else {
            throw PisyaError.message("Invalid contextual replay")
        }
        let files = names.sorted().map { name in (audio.appendingPathComponent(name), meeting.audioOffsets[name] ?? 0) }
        var supplied: [UUID: Range<Double>] = [:]
        for (key, interval) in request.fileLocalBounds ?? [:] {
            guard let id = UUID(uuidString: key), interval.start.isFinite, interval.end.isFinite,
                  interval.start >= 0, interval.end > interval.start, interval.end - interval.start <= 32 else {
                throw PisyaError.message("Invalid contextual replay bounds")
            }
            supplied[id] = interval.start..<interval.end
        }
        let transcriber = Transcriber()
        let result = try await transcriber.replayRecognitionContext(meeting.segments, files: files,
            modelDirectory: modelDirectory, speakerDirectory: root.appendingPathComponent("Models/Speakers"),
            vocabulary: request.vocabulary, selected: targetIDs, suppliedBounds: supplied,
            repeatFirstPass: request.repeatFirstPass ?? true)
        let segments = result.filter { targetIDs.contains($0.id) }
        let diagnostics = await transcriber.recognitionContextDiagnostics()
        try emit(name: meeting.id.uuidString, mode: "context-replay",
            text: segments.map(\.text).joined(separator: " "), seconds: Date().timeIntervalSince(began), extra: [
                "segments": segments.map { ["id": $0.id.uuidString, "start": $0.start, "end": $0.end, "text": $0.text] },
                "contextDiagnostics": diagnostics,
                "boundsSource": supplied.isEmpty ? "estimated_from_saved_segments" : "supplied_where_available",
                "contextSource": "frozen_snapshot",
            ])
    }

    @MainActor static func run() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
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
        if CommandLine.arguments.contains("--recognition-context-replay") {
            let request = try JSONDecoder().decode(ReplayEnvelope.self, from: data)
            try await replay(request.replay, root: userRoot, modelDirectory: directory)
            print("RECOGNITION_QUALITY_OK")
            return
        }
        let request = try JSONDecoder().decode(Request.self, from: data)
        let modes = Set(["pipeline", "acoustic", "auto", "russian", "unpenalized", "russian-unpenalized"])
        guard !request.fixtures.isEmpty, request.modes.allSatisfy(modes.contains),
              request.fixtures.allSatisfy({ !$0.samples.isEmpty && $0.samples.count <= 16000 * 120 && $0.samples.allSatisfy(\.isFinite) }),
              request.fixtures.allSatisfy({ ($0.timelineStart ?? 0).isFinite && ($0.timelineStart ?? 0) >= 0 }),
              request.fixtures.allSatisfy({ fixture in
                  guard let reference = fixture.referenceSamples else { return true }
                  return fixture.track != "remote" && !reference.isEmpty && reference.count <= 16000 * 120
                      && reference.allSatisfy(\.isFinite)
              }),
              !request.modes.contains("acoustic") || request.fixtures.allSatisfy({ $0.samples.count <= 16000 * 30 }) else {
            throw PisyaError.message("Invalid recognition fixtures or modes")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-recognition-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = Transcriber()
        do {
            if request.modes.contains("pipeline") {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                var histories: [String: [TranscriptSegment]] = [:]
                for fixture in request.fixtures {
                    let live = fixture.live ?? true
                    // Fixtures are independent unless explicitly grouped.
                    // Grouped context comes only from previous audio results;
                    // decoder/session state must not leak between fixtures.
                    await transcriber.finishLive()
                    let timelineStart = fixture.timelineStart ?? 0
                    let preceding = fixture.contextGroup.flatMap { histories[$0] }?.filter {
                        $0.end <= timelineStart && $0.end >= timelineStart - 300
                    } ?? []
                    let track = fixture.track == "remote" ? "remote" : "mic"
                    let url = root.appendingPathComponent("fixture-\(track).caf")
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(fixture.samples.count))!
                    buffer.frameLength = AVAudioFrameCount(fixture.samples.count)
                    fixture.samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                    let writer = try AVAudioFile(forWriting: url, settings: format.settings)
                    try writer.write(from: buffer); writer.close()
                    var files = [(url, timelineStart)]
                    if let reference = fixture.referenceSamples {
                        let referenceURL = root.appendingPathComponent("reference-remote.caf")
                        let referenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(reference.count))!
                        referenceBuffer.frameLength = AVAudioFrameCount(reference.count)
                        reference.withUnsafeBufferPointer { referenceBuffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
                        let referenceWriter = try AVAudioFile(forWriting: referenceURL, settings: format.settings)
                        try referenceWriter.write(from: referenceBuffer); referenceWriter.close()
                        files.append((referenceURL, timelineStart))
                    }
                    let began = Date()
                    let recognized = try await transcriber.transcribe(files: files, modelDirectory: directory,
                        context: fixture.context ?? "", speakerDirectory: userRoot.appendingPathComponent("Models/Speakers"),
                        profiles: [], quiet: false, live: live, russianVerification: request.russianVerification ?? true,
                        contextualVerification: request.contextualVerification ?? true,
                        preceding: preceding,
                        collectDiagnostics: request.diagnostics ?? false) { _, _ in }
                    if let group = fixture.contextGroup {
                        let end = recognized.map(\.end).max() ?? timelineStart
                        histories[group] = (preceding + recognized).filter { $0.end >= end - 300 }
                    }
                    let segments = fixture.referenceSamples == nil ? recognized : recognized.filter { $0.audioFile?.contains("-mic.") == true }
                    var extra: [String: Any] = ["live": live,
                        "segments": segments.map { ["start": $0.start - timelineStart, "end": $0.end - timelineStart, "text": $0.text] }]
                    if fixture.contextGroup != nil { extra["contextStart"] = timelineStart; extra["precedingCount"] = preceding.count }
                    if live { extra["russianVerifierLoaded"] = await transcriber.liveRussianModelIdentity() != nil }
                    if request.diagnostics == true { extra["contextDiagnostics"] = await transcriber.recognitionContextDiagnostics() }
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
                let result = russian.recognizeDetailed(fixture.samples)
                let text = result?.text ?? ""
                let vocabulary = SpokenVocabulary(fixture.context ?? "", pronunciations: pronunciations)
                var extra: [String: Any] = ["promptHypothesis": vocabulary.promptHypothesis(text)]
                if request.diagnostics == true {
                    extra["words"] = (result?.words ?? []).map { ["text": $0.text, "start": $0.start, "end": $0.end] }
                }
                try emit(name: fixture.name, mode: "acoustic", text: text, seconds: Date().timeIntervalSince(began),
                         extra: extra)
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
