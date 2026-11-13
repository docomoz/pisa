import Foundation

/// Opt-in full-meeting replay. Source tracks are copied before inference;
/// neither the meeting library nor saved voice profiles are written.
enum RecognitionMeetingBenchmark {
    private struct Request: Decodable {
        let meeting: Meeting
        let vocabulary: String
        let profiles: [VoiceProfile]
        var audioDirectory: String?
        var modelsDirectory: String?
    }

    static func run() async throws {
        let request = try JSONDecoder().decode(Request.self, from: FileHandle.standardInput.readDataToEndOfFile())
        let names = request.meeting.audioFiles.filter { !$0.contains(".clean.") }
        guard !names.isEmpty, Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0 == URL(fileURLWithPath: $0).lastPathComponent && !$0.contains("..") }),
              request.meeting.duration.isFinite, request.meeting.duration > 0,
              names.allSatisfy({ (request.meeting.audioOffsets[$0] ?? 0).isFinite }) else {
            throw PisaError.message("Invalid full-meeting benchmark request")
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa")
        let model: URL
        let speakers: URL
        if let directory = request.modelsDirectory {
            guard NSString(string: directory).isAbsolutePath else {
                throw PisaError.message("Benchmark modelsDirectory must be an absolute path")
            }
            let models = URL(fileURLWithPath: directory, isDirectory: true)
            model = models.appendingPathComponent("Qwen3-ASR")
            speakers = models.appendingPathComponent("Speakers")
        } else {
            let preferences = try JSONDecoder().decode(Preferences.self,
                from: Data(contentsOf: root.appendingPathComponent("preferences.json")))
            if let bookmark = preferences.modelBookmark {
                var stale = false
                model = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
            } else { model = root.appendingPathComponent("Models/Qwen3-ASR") }
            speakers = root.appendingPathComponent("Models/Speakers")
        }
        let granted = model.startAccessingSecurityScopedResource()
        defer { if granted { model.stopAccessingSecurityScopedResource() } }
        let source = request.audioDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appendingPathComponent("Audio", isDirectory: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pisa-meeting-benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let files = try names.map { name -> (URL, Double) in
            let copy = scratch.appendingPathComponent(name)
            try FileManager.default.copyItem(at: source.appendingPathComponent(name), to: copy)
            return (copy, request.meeting.audioOffsets[name] ?? 0)
        }
        // Match AppState.setTurboEnabled: executor priority alone does not
        // prevent macOS from reducing a background app's activity.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated,
            reason: "Turbo transcription benchmark")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let performance = TranscriptionPerformance(mode: .turbo)
        let transcriber = Transcriber()
        await transcriber.resetRecognitionPerformanceDiagnostics()
        SpeakerEmbeddingExtractor.resetInferenceMetrics()
        let began = DispatchTime.now().uptimeNanoseconds
        let segments = try await Task(executorPreference: performance, priority: .userInitiated) {
            try await transcriber.transcribe(files: files, modelDirectory: model,
                context: request.vocabulary, speakerDirectory: speakers,
                profiles: request.profiles, performance: performance, collectDiagnostics: true) { fraction, phase in
                    let event: [String: Any] = ["kind": "progress", "fraction": fraction, "phase": phase,
                        "elapsedSeconds": elapsed(since: began), "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
                    if let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) {
                        FileHandle.standardOutput.write(data + Data([10]))
                    }
                }
        }.value
        let seconds = elapsed(since: began)
        let embeddingMetrics = SpeakerEmbeddingExtractor.inferenceMetrics
        let encodedSegments = try JSONSerialization.jsonObject(with: JSONEncoder().encode(segments))
        let result: [String: Any] = [
            "kind": "result", "mode": "batch-turbo", "turboActivityHeld": true,
            "meetingID": request.meeting.id.uuidString,
            "audioSeconds": request.meeting.duration, "seconds": seconds,
            "segments": encodedSegments,
            "contextDiagnostics": await transcriber.recognitionContextDiagnostics(),
            "recognitionPerformance": await transcriber.recognitionPerformanceDiagnostics(),
            "speakerEmbeddingPerformance": ["calls": embeddingMetrics.attemptedCalls,
                "successfulCalls": embeddingMetrics.successfulCalls, "seconds": embeddingMetrics.inferenceSeconds],
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "physicalMemory": ProcessInfo.processInfo.physicalMemory,
            "processorCount": ProcessInfo.processInfo.activeProcessorCount,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .withoutEscapingSlashes])
        FileHandle.standardOutput.write(data + Data([10]))
        print("RECOGNITION_MEETING_BENCHMARK_OK")
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}
