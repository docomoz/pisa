import AVFoundation
import Foundation

/// Opt-in hardware check. Uses a temporary directory, never the meeting library.
enum AudioCaptureTests {
    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Capture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tone = root.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)!
        pcm.frameLength = 96000
        for i in 0..<96000 { pcm.floatChannelData![0][i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 48000) }
        let fixture = try AVAudioFile(forWriting: tone, settings: format.settings)
        try fixture.write(from: pcm); fixture.close()
        let capture = AudioCapture()
        var failure: String?
        capture.onFailure = { failure = $0 }
        for cycle in 1...2 {
            try await capture.prepare()
            try await capture.start(folder: root, id: UUID())
            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [tone.path]
            do {
                try player.run()
                try await Task.sleep(for: .seconds(3))
            } catch {
                if player.isRunning { player.terminate() }
                _ = try? await capture.stop()
                throw error
            }
            if player.isRunning { player.terminate() }
            let meters = await capture.meterSnapshot()
            let boundary = await capture.transcriptionBoundary()
            let result = try await capture.stop()
            guard failure == nil, result.warning == nil, result.files.count == 2,
                  let boundary, boundary.count == 2, boundary.allSatisfy({ $0.frames > 0 && $0.offset >= 0 }),
                  meters.1.peak > 0.01 else {
                throw PisaError.message("Capture cycle \(cycle) failed: \(failure ?? result.warning ?? "missing tracks or silent system audio")")
            }
            for name in result.files {
                let file = try AVAudioFile(forReading: root.appendingPathComponent(name))
                guard file.length > 0, result.offsets[name] != nil else { throw PisaError.message("Missing recorded frames or offset") }
            }
            print("CAPTURE_CYCLE \(cycle): two tracks, audible system audio, timestamps and restart verified")
        }
    }
}
