import Foundation
import AVFoundation

/// Local, synthetic component integration fixture. This does not instantiate
/// AppState or capture real devices and must never touch a user's recording.
public enum LivePipelineTests {
    @MainActor public static func run() async throws {
        func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw PisyaError.message(message) }
        }
        let payload = try JSONDecoder().decode([String: [Float]].self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard let far = payload["far"], let near = payload["near"], let short = payload["short"],
              !far.isEmpty, !near.isEmpty, !short.isEmpty else { throw PisyaError.message("Missing synthetic far/near/short voices") }
        let rate = 16000
        // Allow the actual synthesized clips to cross the nominal 15 s/25 s
        // boundaries naturally; truncating them would invalidate the test.
        try check(far.count <= rate * 16 && near.count <= rate * 8 && short.count <= rate * 3, "Synthetic voices exceed fixture intervals")
        let userRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisya")
        let preferencesURL = userRoot.appendingPathComponent("preferences.json")
        let preferences = FileManager.default.fileExists(atPath: preferencesURL.path)
            ? try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: preferencesURL)) : Preferences()
        let model: URL
        if let data = preferences.modelBookmark {
            var stale = false
            model = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        } else { model = userRoot.appendingPathComponent("Models/Qwen3-ASR") }
        let access = model.startAccessingSecurityScopedResource()
        defer { if access { model.stopAccessingSecurityScopedResource() } }
        let speakerDirectory = userRoot.appendingPathComponent("Models/Speakers")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-live-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try MeetingLibrary(root: root)
        var meeting = Meeting(title: "Synthetic live fixture", source: "Системный звук")
        let remote = library.audioDirectory.appendingPathComponent("fixture-remote.caf")
        let mic = library.audioDirectory.appendingPathComponent("fixture-mic.caf")
        meeting.audioFiles = [remote.lastPathComponent, mic.lastPathComponent]
        meeting.audioOffsets = [remote.lastPathComponent: 0, mic.lastPathComponent: 0]
        meeting.status = .processing; meeting.liveCommittedUntil = 0
        try library.save(meeting)
        let total = 48 * rate
        var remoteSamples = [Float](repeating: 0, count: total)
        for start in [0, 30 * rate] {
            for i in far.indices { remoteSamples[start + i] += far[i] }
        }
        var micSamples = [Float](repeating: 0, count: total)
        for i in 0..<total {
            if i >= 640 { micSamples[i] += remoteSamples[i - 640] * 0.4 }
            if i >= 860 { micSamples[i] += remoteSamples[i - 860] * 0.12 }
        }
        for i in near.indices { micSamples[18 * rate + i] += near[i] }
        for i in short.indices { micSamples[41 * rate + i] += short[i] }
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        let remoteWriter = try AVAudioFile(forWriting: remote, settings: format.settings)
        let micWriter = try AVAudioFile(forWriting: mic, settings: format.settings)
        var writersClosed = false
        defer { if !writersClosed { remoteWriter.close(); micWriter.close() } }
        func append(_ writer: AVAudioFile, samples: [Float], from: Int, to: Int) throws {
            let count = to - from
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { throw PisyaError.message("Fixture buffer unavailable") }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + from, count: count) }
            try writer.write(from: buffer)
        }
        var written = 0
        func grow(to seconds: Int) throws {
            let end = seconds * rate
            try append(remoteWriter, samples: remoteSamples, from: written, to: end)
            try append(micWriter, samples: micSamples, from: written, to: end)
            written = end
        }
        func boundaries() -> [CaptureTrackBoundary] {
            [CaptureTrackBoundary(url: remote, offset: 0, frames: Int64(written), sampleRate: Double(rate)),
             CaptureTrackBoundary(url: mic, offset: 0, frames: Int64(written), sampleRate: Double(rate))]
        }
        let transcriber = Transcriber()
        var scheduler = LiveTranscriptionSchedule()
        var initialModel: ObjectIdentifier?
        var initialRussianModel: ObjectIdentifier?
        var recognized: [(Double, Double)] = []
        func process(_ window: LiveTranscriptionSchedule.Window, available: Double, stopped: Bool) async throws {
            let temp = root.appendingPathComponent("window-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temp) }
            let files = try CaptureWindow.copy(boundaries(), start: window.start, end: min(available, window.end + 2), directory: temp)
            try check(!files.isEmpty, "No fixture tracks in window")
            var result = try await transcriber.transcribe(files: files.map { ($0.url, $0.offset) }, modelDirectory: model, context: "", speakerDirectory: speakerDirectory, profiles: [], quiet: true, live: true) { _, _ in }
            guard let identity = await transcriber.liveModelIdentity() else { throw PisyaError.message("Live model not retained") }
            if let initialModel { try check(identity == initialModel, "Model was not reused across windows") }
            else { initialModel = identity }
            guard let russianIdentity = await transcriber.liveRussianModelIdentity() else { throw PisyaError.message("Russian verifier not retained") }
            if let initialRussianModel { try check(russianIdentity == initialRussianModel, "Russian verifier was not reused across windows") }
            else { initialRussianModel = russianIdentity }
            var commitEnd = LiveTranscriptionSchedule.safeBoundary(start: window.start, proposed: window.end, segments: result)
            if commitEnd <= window.start + 0.001 {
                if !stopped { _ = scheduler.deferBoundary(window); return }
                // Same conservative fallback as AppState after stop.
                let fallbackFiles = try CaptureWindow.copy(boundaries(), start: window.start, end: window.end, directory: temp)
                result = try await transcriber.transcribe(files: fallbackFiles.map { ($0.url, $0.offset) }, modelDirectory: model, context: "", speakerDirectory: speakerDirectory, profiles: [], quiet: true, live: true) { _, _ in }
                commitEnd = window.end
            } else { result.removeAll { $0.end > commitEnd } }
            result = try result.map { original in
                var segment = original
                guard let name = segment.audioFile else { throw PisyaError.message("Missing playback reference") }
                let originalFile = name.contains("-mic.") ? mic : remote
                try check(FileManager.default.fileExists(atPath: originalFile.path), "Original audio unavailable")
                segment.audioFile = originalFile.lastPathComponent
                return segment
            }
            var latest = try library.read(meeting.id)
            latest.segments.append(contentsOf: result); latest.segments.sort { $0.start < $1.start }
            latest.liveCommittedUntil = commitEnd
            try library.save(latest)
            scheduler.commit(window, through: commitEnd)
            recognized.append((window.start, commitEnd))
        }
        do {
            try grow(to: 17)
            guard let first = scheduler.next(available: 15, stopped: false) else { throw PisyaError.message("First live batch not scheduled") }
            try await process(first, available: 17, stopped: false)
            try grow(to: 32)
            guard let second = scheduler.next(available: 30, stopped: false) else { throw PisyaError.message("Second live batch not scheduled") }
            try await process(second, available: 32, stopped: false)
            let draft = try library.read(meeting.id)
            let draftText = draft.segments.filter { $0.speaker == "Я" }.map(\.text).joined(separator: " ").lowercased()
            print("LIVE_FIXTURE_DRAFT", draftText)
            try check(draftText.split(whereSeparator: { !$0.isLetter }).contains("четверг"), "Near phrase not present in draft before stop")
            let beforePause = scheduler.committed
            try grow(to: 48)
            try check(scheduler.next(available: 46, stopped: false, paused: true) == nil && scheduler.committed == beforePause, "Paused processing advanced cursor")
            let persisted = try library.read(meeting.id)
            try check(persisted.liveCommittedUntil == beforePause && persisted.segments == draft.segments, "Draft cursor or segments failed to persist")
            scheduler = LiveTranscriptionSchedule(committed: beforePause)
            remoteWriter.close(); micWriter.close(); writersClosed = true
            while let tail = scheduler.next(available: 48, stopped: true) {
                try check(tail.start >= beforePause, "Committed prefix scheduled again after stop")
                try await process(tail, available: 48, stopped: true)
            }
            let final = try library.read(meeting.id)
            let localText = final.segments.filter { $0.speaker == "Я" }.map(\.text).joined(separator: " ").lowercased()
            let matches = localText.split(whereSeparator: { !$0.isLetter }).filter { $0 == "четверг" }.count
            try check(matches == 1, "Near keyword was lost or duplicated: \(matches)")
            let shortText = final.segments.filter { $0.speaker == "Я" && $0.start < 44.5 && $0.end > 40.9 }.map(\.text).joined(separator: " ").lowercased()
            let shortMatches = shortText.split(whereSeparator: { !$0.isLetter }).filter { $0 == "да" }.count
            try check(shortMatches == 1, "Short tail answer was lost or duplicated: \(shortMatches), text=\(shortText)")
            try check(final.segments.allSatisfy { $0.audioFile.map { meeting.audioFiles.contains($0) } ?? false }, "Dangling temporary playback reference")
            try check(!recognized.isEmpty && recognized.last?.1 == 48, "Uncommitted tail was not drained")
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            try check(!remaining.contains(where: { $0.hasPrefix("window-") }), "Temporary window leaked")
            print("LIVE_PIPELINE_TEST_OK cursor=\(scheduler.committed) windows=\(recognized.count) near_keyword_count=\(matches) short_count=\(shortMatches)")
        } catch {
            await transcriber.finishLive()
            throw error
        }
        await transcriber.finishLive()
        let releasedModel = await transcriber.liveModelIdentity()
        try check(releasedModel == nil, "Live model was not released")
        let releasedRussianModel = await transcriber.liveRussianModelIdentity()
        try check(releasedRussianModel == nil, "Russian verifier was not released")
    }
}
