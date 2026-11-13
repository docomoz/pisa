import Foundation
import AVFoundation
import Accelerate

/// Local, read-only diagnostics through the application's own library access.
/// Prints numeric measurements only; never exports recordings or transcript text.
enum EchoDiagnostics {
    static func run() async throws {
        if CommandLine.arguments.contains("--asr-preview") { try await transcriptionPreview(); return }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa")
        let library = try MeetingLibrary(root: root)
        let meetings = try library.all().sorted { $0.date < $1.date }
        for m in meetings {
            print("MEETING", m.id, "seconds", m.duration, "mic_segments", m.segments.filter { $0.speaker == "Я" }.count, "segments", m.segments.count)
        }
        for m in meetings.filter({ $0.duration > 900 }).prefix(2) {
            guard let microphone = m.audioFiles.first(where: { $0.contains("-mic.") && !$0.contains(".clean.") }),
                  let remote = m.audioFiles.first(where: { $0.contains("-remote.") }) else { continue }
            let micURL = try library.audioURL(microphone), refURL = try library.audioURL(remote)
            let cleanName = m.segments.first { $0.speaker == "Я" && $0.audioFile?.contains(".clean.") == true }?.audioFile
            var preview: URL?
            if CommandLine.arguments.contains("--fresh-clean") {
                preview = try await AcousticEcho.clean(microphone: micURL, offset: m.audioOffsets[microphone] ?? 0, reference: refURL, referenceOffset: m.audioOffsets[remote] ?? 0) { _, _ in }
            }
            defer { if let preview { try? FileManager.default.removeItem(at: preview) } }
            let clean = try preview.map { try AVAudioFile(forReading: $0) } ?? cleanName.map { try AVAudioFile(forReading: library.audioURL($0)) }
            let mic = try AVAudioFile(forReading: micURL), ref = try AVAudioFile(forReading: refURL)
            let offset = m.audioOffsets[microphone] ?? 0, refOffset = m.audioOffsets[remote] ?? 0
            print("TRACKS", m.id, "mic_rate", mic.processingFormat.sampleRate, "ref_rate", ref.processingFormat.sampleRate, "offset", offset, "reference_offset", refOffset)
            for t in [5.0, 15, 30, 60, 120, 160, 180, 200, 220, 240, 480, 900, 1500, 2400] where t + 4 < m.duration {
                let near = try samples(mic, start: t, seconds: 3)
                let far = try samples(ref, start: t + offset - refOffset - 2, seconds: 7)
                let original = correlation(near, far)
                let evidence = EchoAnalysis.measure(near, far)
                let residual = try clean.map { correlation(try samples($0, start: t, seconds: 3), far) }
                let residualEvidence = try clean.map { EchoAnalysis.measure(try samples($0, start: t, seconds: 3), far) }
                print("ECHO_WINDOW", m.id, "time", t, "raw_rms", rms(near), "raw_corr", original.0, "raw_lag_ms", original.1, "coherence", evidence.coherence, "clean_corr", residual?.0 ?? -1, "clean_lag_ms", residual?.1 ?? 0, "clean_coherence", residualEvidence?.coherence ?? -1)
            }
        }
    }
    private static func transcriptionPreview() async throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa")
        let library = try MeetingLibrary(root: root)
        let preferences = try library.preferences()
        let model: URL
        if let bookmark = preferences.modelBookmark {
            var stale = false
            model = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        } else { model = root.appendingPathComponent("Models/Qwen3-ASR") }
        let access = model.startAccessingSecurityScopedResource()
        defer { if access { model.stopAccessingSecurityScopedResource() } }
        let fixture = CommandLine.arguments.contains("--fixture-preview")
        let meetings = try library.all().filter { fixture ? $0.title == "Проверка фоновой расшифровки" : $0.duration > 900 }.sorted { $0.date < $1.date }
        for (index, meeting) in meetings.prefix(2).enumerated() {
            let time = fixture ? 0 : index == 0 ? 120.0 : 200.0, duration = fixture ? 12.0 : 30.0
            let base = max(0, time - 2)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pisa-asr-preview-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            var clips: [(URL, Double)] = []
            var attributes: [URL: Date] = [:]
            for filename in meeting.audioFiles where !filename.contains(".clean.") {
                let source = try library.audioURL(filename)
                attributes[source] = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let file = try AVAudioFile(forReading: source)
                let sourceStart = max(0, base - (meeting.audioOffsets[filename] ?? 0))
                file.framePosition = AVAudioFramePosition(sourceStart * file.processingFormat.sampleRate)
                let frames = AVAudioFrameCount(min(file.length - file.framePosition, Int64((duration + 4) * file.processingFormat.sampleRate)))
                let buffer = try PCMRead.exact(file, frames: frames)
                let destination = temporary.appendingPathComponent(filename.contains("-mic.") ? "preview-mic.caf" : "preview-remote.caf")
                let writer = try AVAudioFile(forWriting: destination, settings: file.processingFormat.settings)
                try writer.write(from: buffer); writer.close()
                clips.append((destination, 0))
            }
            let began = Date()
            let result = try await Transcriber().transcribe(files: clips, modelDirectory: model, context: preferences.vocabulary, speakerDirectory: root.appendingPathComponent("Models/Speakers"), profiles: [], quiet: true) { _, _ in }
            let visible = result.filter { $0.end > time - base && $0.start < duration + time - base }
            let mic = visible.filter { $0.speaker == "Я" }
            let original = meeting.segments.filter { $0.end > time && $0.start < time + duration && $0.speaker == "Я" }
            let remoteText = visible.filter { $0.speaker != "Я" }.map(\.text).joined(separator: " ")
            let duplicates = mic.filter { EchoDetector.sameWords($0.text, remoteText) }
            let unchanged = try attributes.allSatisfy { url, date in try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == date }
            print("REAL_ASR_PREVIEW", meeting.id, "time", time, "seconds", duration, "old_mic_segments", original.count, "new_mic_segments", mic.count, "new_exact_duplicates", duplicates.count, "all_segments", visible.count, "elapsed", Date().timeIntervalSince(began), "originals_unchanged", unchanged)
        }
    }
    private static func rms(_ x: [Float]) -> Float {
        var value: Float = 0
        if !x.isEmpty { vDSP_rmsqv(x, 1, &value, vDSP_Length(x.count)) }
        return value
    }
    private static func correlation(_ microphone: [Float], _ reference: [Float]) -> (Float, Float) {
        guard microphone.count >= 1000, reference.count > microphone.count else { return (0, 0) }
        var energy: Float = 0
        vDSP_dotpr(microphone, 1, microphone, 1, &energy, vDSP_Length(microphone.count))
        var best: Float = 0, bestLag = 0
        microphone.withUnsafeBufferPointer { mic in reference.withUnsafeBufferPointer { ref in
            for lag in 0...(reference.count - microphone.count) {
                var dot: Float = 0, refEnergy: Float = 0
                vDSP_dotpr(mic.baseAddress!, 1, ref.baseAddress! + lag, 1, &dot, vDSP_Length(microphone.count))
                vDSP_dotpr(ref.baseAddress! + lag, 1, ref.baseAddress! + lag, 1, &refEnergy, vDSP_Length(microphone.count))
                let value = abs(dot) / sqrt(max(1e-20, energy * refEnergy))
                if value > best { best = value; bestLag = lag }
            }
        } }
        return (best, 2000 - Float(bestLag) / 2)
    }
    private static func samples(_ file: AVAudioFile, start: Double, seconds: Double) throws -> [Float] {
        let rate = file.processingFormat.sampleRate
        let leading = max(0, Int(-start * 2000))
        let begin = AVAudioFramePosition(max(0, start) * rate)
        guard begin < file.length else { return Array(repeating: 0, count: Int(seconds * 2000)) }
        file.framePosition = begin
        let frames = AVAudioFrameCount(min(file.length - begin, Int64((seconds - Double(leading) / 2000) * rate)))
        let input = try PCMRead.exact(file, frames: frames)
        let target = AVAudioFormat(standardFormatWithSampleRate: 2000, channels: 1)!
        let converter = AVAudioConverter(from: file.processingFormat, to: target)!
        let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(seconds * 2000 + 128))!
        var delivered = false, error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if delivered { status.pointee = .endOfStream; return nil }
            delivered = true; status.pointee = .haveData; return input
        }
        if let error { throw error }
        var result = Array(repeating: Float(0), count: leading) + Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        let expected = Int(seconds * 2000)
        if result.count < expected { result += Array(repeating: 0, count: expected - result.count) }
        return Array(result.prefix(expected))
    }
}
