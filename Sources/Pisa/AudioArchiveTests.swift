import AVFoundation
import Foundation

enum AudioArchiveTests {
    private static let sampleRate = 48_000.0
    private static let frames = 48_000 * 3 + 173

    @MainActor
    static func run() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("pisa-audio-archive-test-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let library = try MeetingLibrary(root: root.appendingPathComponent("Library", isDirectory: true))

        var meeting = try makeRecording(in: library)
        let rawNames = meeting.audioFiles
        let rawOffsets = meeting.audioOffsets
        let original = try rawNames.map(library.audioURL)
        let originalBytes = try original.map { try Data(contentsOf: $0) }
        let originalWindows = try copyTail(of: meeting, from: library, to: root.appendingPathComponent("Original"))

        var legacy = meeting
        legacy.audioArchive = nil
        legacy.finishTranscription()
        try library.save(legacy)
        let legacyAfterReload = try library.read(legacy.id)
        let legacyReplacements = try await MeetingAudioArchive.prepare(legacyAfterReload, in: library)
        defer { legacyReplacements.forEach { $0.discard() } }
        try check(legacyAfterReload.audioArchive == nil && legacyReplacements.isEmpty, "Legacy recording became eligible")

        meeting.audioArchive = .waitingForTranscription
        meeting.status = .processing
        meeting.liveCommittedUntil = 2
        try library.save(meeting)
        let draftReplacements = try await MeetingAudioArchive.prepare(meeting, in: library)
        defer { draftReplacements.forEach { $0.discard() } }
        try check(draftReplacements.isEmpty, "Live draft staged an archive")

        meeting.status = .failed
        meeting.error = "Interrupted"
        try library.save(meeting)
        let failedReplacements = try await MeetingAudioArchive.prepare(meeting, in: library)
        defer { failedReplacements.forEach { $0.discard() } }
        try check(failedReplacements.isEmpty, "Interrupted first transcription staged an archive")

        meeting.finishTranscription()
        try check(meeting.status == .ready && meeting.liveCommittedUntil == nil && meeting.error == nil && meeting.audioArchive == .pending,
                  "Full transcription did not make archive work durable")
        try library.save(meeting)
        let reopened = try MeetingLibrary(root: library.root)
        let pending = try reopened.read(meeting.id)
        var interruptedRepeat = pending
        interruptedRepeat.status = .failed
        try reopened.save(interruptedRepeat)
        let interruptedReplacements = try await MeetingAudioArchive.prepare(interruptedRepeat, in: reopened)
        defer { interruptedReplacements.forEach { $0.discard() } }
        try check(interruptedReplacements.isEmpty, "An interrupted repeat staged an archive")
        try reopened.save(pending)

        let staged = try await MeetingAudioArchive.prepare(pending, in: reopened)
        defer { staged.forEach { $0.discard() } }
        try check(staged.count == 2, "Full transcription did not stage both raw tracks")
        for (index, url) in original.enumerated() {
            try check(try Data(contentsOf: url) == originalBytes[index], "Staging changed the original recording")
        }
        // Model a process exit after the first atomic replacement. The next
        // startup must finish the other file and skip the already-encoded CAF.
        try MeetingAudioArchive.install([staged[0]], for: pending, in: reopened)
        let remaining = try await MeetingAudioArchive.prepare(try reopened.read(meeting.id), in: reopened)
        defer { remaining.forEach { $0.discard() } }
        try check(remaining.count == 1, "Resuming a partially installed archive did not skip the encoded track")
        try MeetingAudioArchive.install(remaining, for: pending, in: reopened)
        let archived = try reopened.read(meeting.id)
        try check(archived.audioFiles == rawNames && archived.audioOffsets == rawOffsets && archived.segments == meeting.segments,
                  "Archiving modified transcript sources or offsets")
        for (index, url) in original.enumerated() {
            let audio = try AVAudioFile(forReading: url)
            try check(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC, "Archived CAF did not contain AAC")
            try check(audio.length == frames && audio.processingFormat.sampleRate == sampleRate && audio.processingFormat.channelCount == 1,
                      "Archiving changed a raw track's sample timeline")
            let encodedSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            var fileID: AudioFileID?
            guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else {
                throw Failure("Archived CAF could not report its bitrate")
            }
            defer { AudioFileClose(fileID) }
            var bytes: UInt64 = 0
            var size = UInt32(MemoryLayout.size(ofValue: bytes))
            try check(AudioFileGetProperty(fileID, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr,
                      "Archived CAF could not report its AAC payload")
            // CAF reserves header space, which skews size-derived bitrate for a three-second recording.
            let approximateBitRate = Double(bytes * 8) * sampleRate / Double(frames)
            try check(encodedSize < originalBytes[index].count && (94_000...100_000).contains(approximateBitRate),
                      "Archived track did not shrink to the target bitrate")
        }

        let compressedWindows = try copyTail(of: archived, from: reopened, to: root.appendingPathComponent("Compressed"))
        for (baseline, compressed) in zip(originalWindows, compressedWindows) {
            try check(baseline.offset == compressed.offset && baseline.original == compressed.original, "Copied tail lost its source timecode")
            try check(try similarity(of: baseline.url, and: compressed.url) > 0.95, "Archived tail does not match the original timeline")
        }
        try await checkPlaybackAndExport(archived, in: reopened, to: root.appendingPathComponent("Export.m4a"))

        // A quit after file replacement but before the final status save must
        // allow the next launch to finish without encoding AAC a second time.
        let retry = try await MeetingAudioArchive.prepare(archived, in: reopened)
        defer { retry.forEach { $0.discard() } }
        try check(retry.isEmpty, "Resuming a pending archive re-encoded existing AAC")
        try MeetingAudioArchive.install(retry, for: archived, in: reopened)
        var complete = archived
        complete.audioArchive = .complete
        complete.finishTranscription()
        try check(complete.audioArchive == .complete, "Repeated transcription reset the archive")
        try reopened.save(complete)

        try await checkDeletedTrack(in: reopened)
        try await checkPendingAfterLaunch(in: reopened)
        if CommandLine.arguments.contains("--with-recognition") { try await checkRecognition(in: root) }
    }

    @MainActor
    private static func checkRecognition(in root: URL) async throws {
        let sample = try JSONDecoder().decode([Float].self, from: FileHandle.standardInput.readDataToEndOfFile())
        try check(!sample.isEmpty && sample.count <= 480_000, "Missing speech fixture")
        let state = AppState(rootURL: root.appendingPathComponent("Recognition"))
        let userModels = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pisa/Models")
        let models = state.library.root.appendingPathComponent("Models")
        try FileManager.default.createSymbolicLink(at: models, withDestinationURL: userModels)
        state.modelSetup.phase = .ready
        state.preferences.quietProcessing = false
        var meeting = Meeting(title: "Archive speech fixture", source: state.source)
        meeting.titleOrigin = .custom
        meeting.audioArchive = .waitingForTranscription
        meeting.audioFiles = ["\(meeting.id.uuidString)-mic.caf", "\(meeting.id.uuidString)-remote.caf"]
        let prefix = 48_000
        let count = prefix + sample.count + 48_173
        meeting.duration = Double(count) / sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for (index, name) in meeting.audioFiles.enumerated() {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = buffer.frameCapacity
            let samples = buffer.floatChannelData![0]
            samples.initialize(repeating: 0, count: count)
            if index == 0 {
                for frame in sample.indices { samples[prefix + frame] = sample[frame] }
            }
            let file = try AVAudioFile(forWriting: state.library.audioURL(name), settings: format.settings)
            try file.write(from: buffer)
            file.close()
        }
        state.update(meeting)
        state.enqueue(meeting.id)
        let first = try await waitForRecognition(meeting.id, in: state)
        try check(first.audioFiles == meeting.audioFiles && first.segments.contains { $0.audioFile == meeting.audioFiles[0] },
                  "First batch did not link microphone speech to the raw track")
        state.enqueue(meeting.id, reprocess: true)
        let repeated = try await waitForRecognition(meeting.id, in: state)
        try check(repeated.audioFiles == meeting.audioFiles && repeated.segments.contains { $0.audioFile == meeting.audioFiles[0] },
                  "Repeated transcription did not read the AAC microphone")
        let audio = try FileManager.default.contentsOfDirectory(atPath: state.library.audioDirectory.path)
        try check(Set(audio) == Set(meeting.audioFiles), "Recognition left extra audio in the library")
    }

    @MainActor
    private static func waitForRecognition(_ id: UUID, in state: AppState) async throws -> Meeting {
        let deadline = ContinuousClock.now + .seconds(150)
        while ContinuousClock.now < deadline {
            let meeting = try state.library.read(id)
            if meeting.status == .failed { throw Failure(meeting.error ?? "Transcription failed") }
            if meeting.status == .ready && meeting.audioArchive == .complete && state.processingID == nil { return meeting }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Transcription or archiving did not finish")
    }

    private static func makeRecording(in library: MeetingLibrary) throws -> Meeting {
        var result = Meeting(title: "Archive test", source: "Системный звук")
        let mic = "\(result.id.uuidString)-mic.caf"
        let remote = "\(result.id.uuidString)-remote.caf"
        result.audioFiles = [mic, remote]
        result.audioOffsets = [mic: 0.0625, remote: 0.125]
        result.duration = Double(frames) / sampleRate + 0.125
        var segment = TranscriptSegment(start: 2.85, end: 3.02, speaker: "Я", text: "Проверка ссылки")
        segment.audioFile = mic
        result.segments = [segment]

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for (name, frequency) in [(mic, 173.0), (remote, 283.0)] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            let samples = buffer.floatChannelData![0]
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<frames {
                let time = Double(index) / sampleRate
                let carrier = sin(2 * .pi * time * (frequency + 31 * time))
                let envelope = 0.35 + 0.25 * sin(42 * time)
                samples[index] = Float(carrier * envelope)
            }
            let file = try AVAudioFile(forWriting: library.audioURL(name), settings: format.settings)
            try file.write(from: buffer)
            file.close()
        }
        return result
    }

    private static func copyTail(of meeting: Meeting, from library: MeetingLibrary, to directory: URL) throws -> [CaptureWindowFile] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let boundaries = try meeting.audioFiles.map { name in
            CaptureTrackBoundary(url: try library.audioURL(name), offset: meeting.audioOffsets[name] ?? 0,
                                 frames: Int64(frames), sampleRate: sampleRate)
        }
        let result = try CaptureWindow.copy(boundaries, start: 2.75, end: meeting.duration, directory: directory)
        try check(result.count == 2, "Could not seek to the tail of both raw tracks")
        return result
    }

    private static func similarity(of baseline: URL, and candidate: URL) throws -> Double {
        let original = try AVAudioFile(forReading: baseline)
        let encoded = try AVAudioFile(forReading: candidate)
        try check(original.length == encoded.length && original.length > 2048, "Seeking dropped part of the ending")
        let frames = AVAudioFrameCount(original.length)
        let x = try PCMRead.exact(original, frames: frames)
        let y = try PCMRead.exact(encoded, frames: frames)
        let a = x.floatChannelData![0]
        let b = y.floatChannelData![0]
        var dot = 0.0
        var aEnergy = 0.0
        var bEnergy = 0.0
        for index in 0..<Int(frames) {
            let first = Double(a[index]), second = Double(b[index])
            dot += first * second
            aEnergy += first * first
            bEnergy += second * second
        }
        return dot / sqrt(aEnergy * bEnergy)
    }

    private static func checkPlaybackAndExport(_ meeting: Meeting, in library: MeetingLibrary, to url: URL) async throws {
        let sources = MeetingAudioExport.playbackSources(for: meeting, in: library)
        let prepared = await MeetingAudioExport.preparePlayback(sources)
        guard let prepared else { throw Failure("Archived tracks could not prepare playback") }
        let tracks = try await prepared.asset.loadTracks(withMediaType: .audio)
        try check(tracks.count == 2 && prepared.sources == sources, "Archived playback dropped a raw track")
        try check(abs(prepared.duration - meeting.duration) < 1 / sampleRate, "Merged playback changed the track offsets")
        try await MeetingAudioExport.write(meeting, from: library, to: url)
        let exported = try AVAudioFile(forReading: url)
        let duration = Double(exported.length) / exported.processingFormat.sampleRate
        try check(abs(duration - meeting.duration) < 0.03, "Exported audio did not retain the meeting duration")
    }

    @MainActor
    private static func checkDeletedTrack(in library: MeetingLibrary) async throws {
        var meeting = try makeRecording(in: library)
        meeting.audioArchive = .waitingForTranscription
        meeting.finishTranscription()
        try library.save(meeting)
        let staged = try await MeetingAudioArchive.prepare(meeting, in: library)
        defer { staged.forEach { $0.discard() } }
        try check(staged.count == 2, "Deletion test did not stage both tracks")

        let removedName = meeting.audioFiles[0]
        let removedURL = try library.audioURL(removedName)
        _ = try library.removeAudio(from: meeting, names: [removedName])
        var wasRejected = false
        do { try MeetingAudioArchive.install(staged, for: meeting, in: library) }
        catch { wasRejected = true }
        try check(wasRejected && !FileManager.default.fileExists(atPath: removedURL.path),
                  "Installing a stale archive restored deleted audio")
    }

    @MainActor
    private static func checkPendingAfterLaunch(in library: MeetingLibrary) async throws {
        var meeting = try makeRecording(in: library)
        meeting.audioArchive = .waitingForTranscription
        meeting.finishTranscription()
        try library.save(meeting)
        let state = AppState(rootURL: library.root)
        let deadline = ContinuousClock.now + .seconds(10)
        while try library.read(meeting.id).audioArchive != .complete && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let archived = try library.read(meeting.id)
        try check(state.meetings.contains { $0.id == archived.id && $0.audioArchive == .complete },
                  "App did not resume the pending archive after launch")
        for name in meeting.audioFiles {
            let url = try library.audioURL(name)
            let track = try AVAudioFile(forReading: url)
            try check(track.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
                      "Startup marked the archive complete without compressing both files")
        }
    }

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
