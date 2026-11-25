import Foundation
import AVFoundation

enum EchoRegressionTests {
    static func run() async throws {
        func check(_ value: Bool, _ message: String) throws { if !value { throw PisaError.message(message) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pisa-echo-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        func write(_ samples: [Float], _ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer); file.close(); return url
        }
        var seed: UInt64 = 9351
        func noise(_ count: Int) -> [Float] {
            var previous: Float = 0
            return (0..<count).map { _ in
                seed = seed &* 6364136223846793005 &+ 1
                previous = 0.7 * previous + 0.3 * Float(Int64(bitPattern: seed) >> 40) / Float(1 << 23)
                return previous * 0.3
            }
        }
        let tone = (0..<12000).map { Float(sin(Double($0) * 2 * .pi * 200 / 2000)) }
        try check(!EchoAnalysis.measure(Array(tone[4000..<10000]), tone).reliableAlignment, "Periodic tones must not set the delay")
        try check(EchoAlignment.referencePosition(microphonePosition: 160000, offset: 0.1, referenceOffset: 0.2, delay: 0.05) == 159200, "Reference mapping sign/offset applied incorrectly")
        let frames = 16000 * 50
        let playback = noise(frames + 32000)
        // A quiet, room-filtered playback can have a clear delay peak even
        // when independently captured sound dominates the microphone.
        // The first five seconds of a 15-second live window have no playback leak.
        let windowLength = 16_000 * 15
        let clockLead = 4_000
        let independent = noise(windowLength)
        let distantMic = independent.indices.map { index in
            independent[index] * 0.22 + (index < 80_000 ? 0 : playback[index + clockLead] * 0.1)
        }
        let distantURL = try write(distantMic, "distant-mic.caf")
        let playbackURL = try write(Array(playback.prefix(windowLength)), "distant-remote.caf")
        let distantAlignment = try await EchoAlignment.estimate(microphone: AVAudioFile(forReading: distantURL),
            reference: AVAudioFile(forReading: playbackURL), offset: 0, referenceOffset: 0) { _, _ in }
        try check(abs(distantAlignment.delay(at: 7) + 0.25) < 0.01,
                  "Consistent weak playback across independent probes must recover a late system reference")
        let distantClean = try await AcousticEcho.clean(microphone: distantURL, offset: 0,
            reference: playbackURL, referenceOffset: 0) { _, _ in }
        let nearStart = 7 * 16_000
        let cleanedSpeech = try AcousticEcho.frame(AVAudioFile(forReading: distantClean),
            at: Int64(nearStart), count: 3 * 16_000)
        var nearPower = 0.0, retainedNear = 0.0
        for i in cleanedSpeech.indices {
            let near = Double(independent[nearStart + i]) * 0.22
            nearPower += near * near
            retainedNear += near * Double(cleanedSpeech[i])
        }
        try check(retainedNear / nearPower > 0.6, "Aligning distant playback suppressed independent mic audio")
        // Live windows can supply previously committed audio to train AEC.
        // The recognizer must receive only the new suffix, sample-aligned
        // even when its beginning is not a WebRTC frame boundary.
        let discard = Int64(6 * 16_000 + 71)
        let suffix = try await AcousticEcho.clean(microphone: distantURL, offset: 2,
            reference: playbackURL, referenceOffset: 2, outputStart: 2 + Double(discard) / 16_000) { _, _ in }
        let suffixFile = try AVAudioFile(forReading: suffix)
        try check(suffixFile.length == Int64(windowLength) - discard, "Committed microphone audio reached recognition")
        let suffixSpeech = try AcousticEcho.frame(suffixFile, at: Int64(nearStart) - discard, count: cleanedSpeech.count)
        try check(suffixSpeech == cleanedSpeech, "Preroll shifted or changed the recognized audio")
        var briefCopy = independent
        for i in 96_000..<144_000 { briefCopy[i] = distantMic[i] }
        let isolatedURL = try write(briefCopy, "isolated-mic.caf")
        let isolatedAlignment = try await EchoAlignment.estimate(microphone: AVAudioFile(forReading: isolatedURL),
            reference: AVAudioFile(forReading: playbackURL), offset: 0, referenceOffset: 0) { _, _ in }
        try check(isolatedAlignment.points.isEmpty, "One weak match must not align unrelated speech")
        var recording = [Float](repeating: 0, count: frames)
        for t in recording.indices {
            let index = t < 25 * 16000 ? t - 800 : t + 15360
            for (tap, gain): (Int, Float) in [(0, 0.5), (137, 0.16), (423, -0.07)] where index - tap >= 0 && index - tap < playback.count {
                recording[t] += playback[index - tap] * gain
            }
        }
        let micURL = try write(recording, "jump-mic.caf"), farURL = try write(playback, "jump-remote.caf")
        let mapping = try await EchoAlignment.estimate(microphone: AVAudioFile(forReading: micURL), reference: AVAudioFile(forReading: farURL), offset: 0, referenceOffset: 0) { _, _ in }
        try check(abs(mapping.delay(at: 10) - 0.05) < 0.01, "Initial delay was not found")
        try check(abs(mapping.delay(at: 35) + 0.96) < 0.01, "Negative delay after clock jump was not found")
        let cleanURL = try await AcousticEcho.clean(microphone: micURL, offset: 0, reference: farURL, referenceOffset: 0) { _, _ in }
        defer { try? FileManager.default.removeItem(at: cleanURL) }
        let cleanFile = try AVAudioFile(forReading: cleanURL)
        try check(cleanFile.length == Int64(frames), "Alignment changed the mic PCM length")
        func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count)) }
        for seconds in [12, 35] {
            let cleaned = try AcousticEcho.frame(cleanFile, at: Int64(seconds * 16000), count: 16000 * 3)
            let raw = Array(recording[seconds * 16000..<(seconds + 3) * 16000])
            let erle = 10 * log10(max(1e-12, energy(raw)) / max(1e-12, energy(cleaned)))
            print("ECHO_CLOCK_JUMP", seconds, "suppression_db", erle)
            try check(erle > 12, "Echo survived clock alignment at \(seconds)s")
        }
        print("ECHO_ALIGNMENT_TEST_OK samples", cleanFile.length, "initial_delay", mapping.delay(at: 10), "after_jump", mapping.delay(at: 35))
        let near = noise(16000 * 5)
        for gain: Float in [1, 0.1, 0.03] {
            var mixed = recording
            let begin = 16000 * 23
            for i in near.indices { mixed[begin + i] += near[i] * gain }
            let mixedURL = try write(mixed, "double-talk-mic.caf")
            let cleanedURL = try await AcousticEcho.clean(microphone: mixedURL, offset: 0, reference: farURL, referenceOffset: 0) { _, _ in }
            defer { try? FileManager.default.removeItem(at: cleanedURL) }
            let file = try AVAudioFile(forReading: cleanedURL)
            let output = try AcousticEcho.frame(file, at: Int64(begin), count: near.count)
            var dot = 0.0, power = 0.0
            for i in near.indices { dot += Double(output[i] * near[i] * gain); power += Double(near[i] * near[i] * gain * gain) }
            let retained = dot / max(1e-12, power)
            print("ECHO_ACTUAL_NEAR_PRESERVATION", "gain", gain, "retained", retained)
            if gain == 1 { try check(retained > 0.45, "Near-end signal was suppressed around the clock jump") }
        }
    }
}
