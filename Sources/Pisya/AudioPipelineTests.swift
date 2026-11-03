import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

enum AudioPipelineTests {
    @MainActor static func runSpeech() async throws {
        let payload = try JSONDecoder().decode([String: [Float]].self, from: FileHandle.standardInput.readDataToEndOfFile())
        guard let far = payload["far"], let other = payload["other"] else { throw PisyaError.message("Missing synthetic voices") }
        let libraryRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisya")
        let library = try MeetingLibrary(root: libraryRoot)
        let preferences = try library.preferences()
        let model: URL
        if let data = preferences.modelBookmark {
            var stale = false
            model = try URL(resolvingBookmarkData: data, options: .withSecurityScope, bookmarkDataIsStale: &stale)
        } else { model = libraryRoot.appendingPathComponent("Models/Qwen3-ASR") }
        let access = model.startAccessingSecurityScopedResource()
        defer { if access { model.stopAccessingSecurityScopedResource() } }
        let speakers = libraryRoot.appendingPathComponent("Models/Speakers")
        if CommandLine.arguments.contains("--quiet-diagnostic") {
            try await quietDiagnostic(payload: payload, model: model)
            return
        }
        let engine = try SpeakerEngine(directory: speakers)
        func vector(_ samples: [Float], first: Bool) throws -> [Float] {
            let middle = samples.count / 2
            let slice = first ? Array(samples[..<middle]) : Array(samples[middle...])
            guard let v = engine.vector(slice) else { throw PisyaError.message("Synthetic voice embedding unavailable") }
            return v
        }
        let a = try vector(far, first: true), a2 = try vector(far, first: false)
        let b = try vector(other, first: true), b2 = try vector(other, first: false)
        print("VOICE_FIXTURE same_a=\(VoiceMatcher.similarity(a,a2)) same_b=\(VoiceMatcher.similarity(b,b2)) cross=\(VoiceMatcher.similarity(a,b))")
        var segments: [TranscriptSegment] = []
        for i in 0..<48 {
            var s = TranscriptSegment(start: Double(i * 4), end: Double(i * 4 + 4), speaker: "Собеседники", text: "Synthetic")
            s.embedding = [a,b,a2,b2][i % 4]; segments.append(s)
        }
        let assigned = SpeakerClustering.assign(segments, profiles: [])
        guard Set(assigned.map(\.speaker)).count == 2, assigned[0].speaker == assigned[2].speaker, assigned[0].speaker != assigned[1].speaker else { throw PisyaError.message("Synthetic voices were not separated consistently") }
        var conversation: [Float] = []
        for _ in 0..<4 {
            conversation += far + Array(repeating: 0, count: 8000) + other + Array(repeating: 0, count: 8000)
        }
        var diarized: [TranscriptSegment] = []
        for start in stride(from: 0, to: conversation.count, by: 16000 * 60) {
            let chunk = Array(conversation[start..<min(conversation.count, start + 16000 * 60)])
            for region in engine.regions(chunk) {
                var s = TranscriptSegment(start: Double(start)/16000 + region.start, end: Double(start)/16000 + region.end, speaker: "Собеседники", text: "Synthetic")
                s.embedding = region.embedding; diarized.append(s)
            }
        }
        let labels = SpeakerClustering.assign(diarized, profiles: [])
        let count = Set(labels.filter { $0.speaker != "Собеседники" }.map(\.speaker)).count
        print("DIARIZATION_MULTI_WINDOW_FIXTURE seconds=\(Double(conversation.count)/16000) regions=\(labels.count) speakers=\(count)")
        guard count == 2 else { throw PisyaError.message("Repeated two-voice conversation fragmented into \(count) speakers") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-speech-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let remote = root.appendingPathComponent("fixture-remote.caf"), mic = root.appendingPathComponent("fixture-mic.caf")
        var echo = [Float](repeating: 0, count: far.count)
        for i in far.indices {
            if i >= 640 { echo[i] += far[i-640] * 0.4 }
            if i >= 860 { echo[i] += far[i-860] * 0.12 }
        }
        for (url, samples) in [(remote, far), (mic, echo)] {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer); file.close()
        }
        let began = Date()
        let result = try await Transcriber().transcribe(files: [(remote,0),(mic,0)], modelDirectory: model, context: "", speakerDirectory: speakers, profiles: [], quiet: true) { _, _ in }
        let micSegments = result.filter { $0.speaker == "Я" }
        print("SPEECH_FIXTURE segments=\(result.count) microphone_segments=\(micSegments.count) seconds=\(Date().timeIntervalSince(began))")
        for s in micSegments { print("SYNTHETIC_MIC_TEXT", s.start, s.text) }
        if let name = micSegments.first?.audioFile {
            let f = try AVAudioFile(forReading: root.appendingPathComponent(name))
            let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
            try f.read(into: buf)
            let data = buf.floatChannelData![0]
            for t in stride(from: 0, to: Int(buf.frameLength), by: 16000) {
                let end = min(Int(buf.frameLength),t+16000)
                var e: Double = 0
                for i in t..<end { e += Double(data[i] * data[i]) }
                print("CLEAN_RMS",t/16000,sqrt(e/Double(end-t)))
            }
        }
        let farOnlyPassed = !result.isEmpty && micSegments.isEmpty
        guard let near = payload["near"] else { throw PisyaError.message("Missing near speech") }
        func writeMicrophone(_ samples: [Float]) throws {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            let file = try AVAudioFile(forWriting: mic, settings: format.settings); try file.write(from: buffer); file.close()
        }
        try writeMicrophone(near)
        let nearOnly = try await Transcriber().transcribe(files: [(mic,0)], modelDirectory: model, context: "", speakerDirectory: speakers, profiles: [], quiet: true) { _, _ in }
        let nearText = nearOnly.map(\.text).joined(separator: " ").lowercased()
        print("NEAR_SPEECH_FIXTURE", nearText)
        guard nearText.contains("четверг"), nearOnly.contains(where: { $0.embedding != nil && $0.speaker == "Я" }) else { throw PisyaError.message("Near speech or remembered voice evidence lost") }
        var mixed = echo
        let nearStart = 16000 * 5
        if mixed.count < nearStart + near.count { mixed += Array(repeating: 0, count: nearStart + near.count - mixed.count) }
        for i in near.indices { mixed[nearStart+i] += near[i] }
        try writeMicrophone(mixed)
        let doubleTalk = try await Transcriber().transcribe(files: [(remote,0),(mic,0)], modelDirectory: model, context: "", speakerDirectory: speakers, profiles: [], quiet: true) { _, _ in }
        let mixedText = doubleTalk.filter { $0.speaker == "Я" }.map(\.text).joined(separator: " ").lowercased()
        print("DOUBLE_TALK_SPEECH_FIXTURE", mixedText)
        guard mixedText.contains("четверг") else { throw PisyaError.message("Near words lost in double-talk") }
        guard let short = payload["short"] else { throw PisyaError.message("Missing short utterance") }
        try writeMicrophone(short.map { $0 * 0.1 })
        let shortOnly = try await Transcriber().transcribe(files: [(mic,0)], modelDirectory: model, context: "", speakerDirectory: speakers, profiles: [], quiet: true) { _, _ in }
        let shortText = shortOnly.map(\.text).joined(separator: " ").lowercased().filter { $0.isLetter }
        print("QUIET_SHORT_NEAR_ASR", shortText)
        guard !shortText.isEmpty else { throw PisyaError.message("Quiet short near speech was rejected as nonspeech") }

        do {
            let writer = try AVAudioFile(forWriting: remote, settings: format.settings)
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
            silence.frameLength = 16000; silence.floatChannelData![0].initialize(repeating: 0, count: 16000)
            try writer.write(from: silence); writer.close()
        }
        let pairedShort = try await Transcriber().transcribe(files: [(mic,0),(remote,0)], modelDirectory: model, context: "", speakerDirectory: speakers, profiles: [], quiet: true) { _, _ in }
        let pairedText = pairedShort.filter { $0.speaker == "Я" }.map(\.text).joined(separator: " ").lowercased().filter { $0.isLetter }
        print("QUIET_SHORT_SILENT_REFERENCE_ASR", pairedText)
        guard pairedText.contains(shortText) else { throw PisyaError.message("Quiet short near speech was lost with a silent reference") }
        let longFrames = 16000 * 60
        var longFar = [Float](repeating: 0, count: longFrames + 32000)
        for i in 0..<longFrames { longFar[i] = far[i % far.count] }
        do {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(longFar.count))!
            buffer.frameLength = AVAudioFrameCount(longFar.count)
            longFar.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: longFar.count) }
            let writer = try AVAudioFile(forWriting: remote, settings: format.settings); try writer.write(from: buffer); writer.close()
        }
        for testShort in [true, false] {
            var clockMic = [Float](repeating: 0, count: longFrames)
            for t in clockMic.indices {
                let index = t < 25 * 16000 ? t - 640 : t + 15360
                if index >= 0 && index < longFar.count { clockMic[t] += longFar[index] * 0.4 }
                if index >= 220 && index - 220 < longFar.count { clockMic[t] += longFar[index - 220] * 0.12 }
            }
            let speech = testShort ? short : near
            let begin = Int((testShort ? 24.8 : 24.0) * 16000)
            for i in speech.indices where begin + i < clockMic.count { clockMic[begin + i] += speech[i] * 0.1 }
            try writeMicrophone(clockMic)
            if testShort {
                let mapping = try await EchoAlignment.estimate(microphone: AVAudioFile(forReading: mic), reference: AVAudioFile(forReading: remote), offset: 0, referenceOffset: 0) { _, _ in }
                print("QUIET_ALIGNMENT_POINTS", mapping.points.map { "\($0.time):\($0.delay)" }.joined(separator: ","))
                let diagnostic = try await AcousticEcho.clean(microphone: mic, offset: 0, reference: remote, referenceOffset: 0) { _, _ in }
                defer { try? FileManager.default.removeItem(at: diagnostic) }
                let file = try AVAudioFile(forReading: diagnostic)
                let window = try AcousticEcho.frame(file, at: Int64(begin), count: short.count)
                var dot = 0.0, power = 0.0
                for i in short.indices { dot += Double(window[i] * short[i] * 0.1); power += Double(short[i] * short[i] * 0.01) }
                print("QUIET_ACTUAL_PCM_RETAINED", dot / max(1e-12, power))
                print("QUIET_ACTUAL_VAD", try SpeechDetector().regions(in: diagnostic).filter { $0.end > 24 && $0.start < 26 }.map { "\($0.start)-\($0.end)" }.joined(separator: ","))
                let knownCrop = try AcousticEcho.frame(file, at: Int64(24.6 * 16000), count: Int(1.2 * 16000))
                let qwen = try await Qwen3ASRModel.fromModelDirectory(model)
                let answer = qwen.generate(audio: MLXArray(knownCrop), maxTokens: 64, context: "", language: nil, chunkDuration: 24, repetitionPenalty: 1.1)
                print("QUIET_KNOWN_CROP_ASR", answer.text)
            }
            let result = try await Transcriber().transcribe(files: [(remote,0),(mic,0)], modelDirectory: model, context: "", speakerDirectory: speakers, profiles: [], quiet: true) { _, _ in }
            let text = result.filter { $0.speaker == "Я" }.map(\.text).joined(separator: " ").lowercased()
            print("QUIET_CLOCK_JUMP_ASR", "short", testShort, text)
            if testShort {
                guard text.filter({ $0.isLetter }).contains(shortText) else { throw PisyaError.message("Quiet short answer was lost at the clock jump") }
            } else { guard text.contains("четверг") else { throw PisyaError.message("Quiet near phrase was lost across the clock jump") } }
        }
        let starts = [8.0,23.8,47.8]
        var boundary = [Float](repeating: 0, count: 16000 * 51)
        for time in starts { for i in short.indices { boundary[Int(time * 16000) + i] += short[i] } }
        try writeMicrophone(boundary)
        let detected = try SpeechDetector().regions(in: mic)
        print("SHORT_BOUNDARY_VAD_FIXTURE", detected.map { "\($0.start)-\($0.end)" }.joined(separator: ","))
        for time in starts {
            guard detected.contains(where: { $0.start < time + Double(short.count)/16000 && $0.end > time }) else { throw PisyaError.message("Short answer lost at boundary \(time)") }
        }
        guard farOnlyPassed else { throw PisyaError.message("Far-only synthetic speech duplicated on microphone") }
        print("SPEECH_PIPELINE_TEST_OK")
    }
    @MainActor private static func quietDiagnostic(payload: [String: [Float]], model: URL) async throws {
        guard let far = payload["far"], let short = payload["short"] else { throw PisyaError.message("Missing fixture") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-quiet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func write(_ samples: [Float], _ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try writer.write(from: buffer); writer.close(); return url
        }
        let count = 32 * 16000, start = Int(24.8 * 16000)
        let playback = (0..<(count + 32000)).map { far[$0 % far.count] }
        var mic = [Float](repeating: 0, count: count)
        for t in mic.indices {
            let k = t < 400000 ? t - 640 : t + 15360
            if k >= 0 { mic[t] += playback[k] * 0.4 }
            if k >= 220 { mic[t] += playback[k - 220] * 0.12 }
        }
        for i in short.indices { mic[start + i] += short[i] * 0.1 }
        let micURL = try write(mic, "fixture-mic.caf"), refURL = try write(playback, "fixture-remote.caf")
        let clean = try await AcousticEcho.clean(microphone: micURL, offset: 0, reference: refURL, referenceOffset: 0) { _, _ in }
        print("QUIET_DIAGNOSTIC_VAD", try SpeechDetector().regions(in: clean).filter { $0.end > 24 && $0.start < 26 }.map { "\($0.start)-\($0.end)" })
        let crop = try AcousticEcho.frame(AVAudioFile(forReading: clean), at: Int64(24.6 * 16000), count: 19200)
        let qwen = try await Qwen3ASRModel.fromModelDirectory(model)
        for (label, context, language): (String, String, String?) in [("auto", "", nil), ("hint", "Разговор на русском языке", nil), ("forced", "", "Russian")] {
            let r = qwen.generate(audio: MLXArray(crop), maxTokens: 64, context: context, language: language, chunkDuration: 24, repetitionPenalty: 1.1)
            print("QUIET_LANGUAGE_PROBE", label, r.language ?? "nil", r.text)
        }
        print("QUIET_DIAGNOSTIC_OK")
    }
    static func run() async throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw PisyaError.message(message) } }
        var seed: UInt64 = 741
        func noise(_ count: Int) -> [Float] {
            var previous: Float = 0
            return (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                let n = Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23)
                previous = 0.6 * previous + 0.4 * n
                return previous * 0.35
            }
        }
        func energy(_ x: ArraySlice<Float>) -> Double { x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count)) }
        let frames = 16000 * 12
        let reference = noise(frames + 16000), near = noise(frames)
        for delay in [0, 320, 800, 2400, 5600] {
            let processor = try AcousticEcho()
            var microphone = [Float](repeating: 0, count: frames)
            for t in 0..<frames {
                for (tap, gain) in [(0, Float(0.5)), (137, Float(0.16)), (423, Float(-0.07))] where t >= delay + tap {
                    microphone[t] += reference[t - delay - tap] * gain
                }
            }
            var clean: [Float] = []
            for t in stride(from: 0, to: frames, by: 320) {
                // Exactly the same +100ms reference lookahead as the file pipeline.
                clean += try processor.process(microphone: Array(microphone[t..<t+320]), reference: Array(reference[t+1600..<t+1920]))
            }
            let erle = 10 * log10(max(1e-12, energy(microphone[96000...])) / max(1e-12, energy(clean[96000...])))
            print("AEC_FAR delay_ms=\(Double(delay)/16) suppression_db=\(String(format: "%.1f", erle))")
            try check(erle > 12, "Недостаточное подавление эха при задержке \(delay)")
        }
        let processor = try AcousticEcho()
        var output: [Float] = []
        for t in stride(from: 0, to: frames, by: 320) {
            var mic = [Float](repeating: 0, count: 320)
            for i in 0..<320 { mic[i] = (t+i >= 320 ? reference[t+i-320] * 0.5 : 0) + (t >= 96000 ? near[t+i] : 0) }
            output += try processor.process(microphone: mic, reference: Array(reference[t+1600..<t+1920]))
        }
        var dot: Double = 0, norm: Double = 0
        for i in 112000..<frames-AcousticEcho.latency { dot += Double(output[i + AcousticEcho.latency] * near[i]); norm += Double(near[i] * near[i]) }
        let retained = dot / norm
        print("AEC_DOUBLE_TALK retained_near_gain=\(String(format: "%.3f", retained))")
        try check(retained > 0.5, "Потеря локального голоса при одновременной речи")
        let nearOnly = try AcousticEcho()
        var nearOutput: [Float] = []
        for t in stride(from: 0, to: frames, by: 320) {
            nearOutput += try nearOnly.process(microphone: Array(near[t..<t+320]), reference: Array(repeating: 0, count: 320))
        }
        let ratio = energy(nearOutput[32000...]) / energy(near[32000...])
        print("AEC_NEAR_ONLY energy_ratio=\(String(format: "%.3f", ratio))")
        try check(ratio > 0.8 && ratio < 1.2, "Изменился локальный голос без системного звука")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisya-pipeline-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for rate in [24000.0, 48000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let count = Int(rate * 2.035)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.11)) * 0.1 }
            let mic = root.appendingPathComponent("fixture-mic.caf"), ref = root.appendingPathComponent("fixture-remote.caf")
            for url in [mic, ref] { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer); file.close() }
            let source = try AVAudioFile(forReading: mic)
            let exact = try PCMRead.exact(source, frames: AVAudioFrameCount(source.length), maxChunk: 333)
            try check(Int(exact.frameLength) == count && source.framePosition == source.length, "Короткие чтения потеряли хвост")
            try check(abs(exact.floatChannelData![0][count - 1] - buffer.floatChannelData![0][count - 1]) < 0.0001, "Повреждён конец PCM")
            let result = try await AcousticEcho.clean(microphone: mic, offset: 0.035, reference: ref, referenceOffset: 0) { _, _ in }
            let file = try AVAudioFile(forReading: result)
            let seconds = Double(file.length) / file.processingFormat.sampleRate
            print("AEC_FILE rate=\(Int(rate)) output_seconds=\(seconds)")
            try check(abs(seconds - 2.035) < 0.005, "Потерян хвост файла при преобразовании")
            try check(FileManager.default.fileExists(atPath: mic.path), "Исходная дорожка изменена")
        }
        print("AUDIO_PIPELINE_TEST_OK")
    }
}
