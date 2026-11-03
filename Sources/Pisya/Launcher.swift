import Foundation
import AppKit
import AVFoundation
import SwiftUI

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--model-setup-self-test") {
            Task { @MainActor in
                do { try await ModelSetupTests.run(); exit(0) }
                catch { print("MODEL_SETUP_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--model-download-smoke-test") {
            Task { @MainActor in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Model-Smoke-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                do {
                    guard let manifest = Bundle.main.url(forResource: "models", withExtension: "json") else { throw ModelInstallError.invalidManifest }
                    let assets = try JSONDecoder().decode([ModelAsset].self, from: Data(contentsOf: manifest))
                    guard let small = assets.first(where: { $0.path == "Qwen3-ASR/config.json" }) else { throw ModelInstallError.invalidManifest }
                    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                    let fixture = root.appendingPathComponent("manifest.json")
                    try JSONEncoder().encode([small]).write(to: fixture)
                    let setup = ModelSetup(root: root, manifestURL: fixture, customModel: { nil }, usesCustomModel: { false })
                    setup.phase = .available; setup.install(onReady: {})
                    while setup.busy { try await Task.sleep(nanoseconds: 10_000_000) }
                    guard setup.ready else { throw PisyaError.message(setup.error ?? "Model setup did not become ready") }
                    let ready = try await ModelInstaller(root: root, assets: [small]).isReady()
                    guard ready else { throw PisyaError.message("Downloaded model did not verify") }
                    print("MODEL_DOWNLOAD_SMOKE_OK native_https sandbox sha256 live_readiness")
                    exit(0)
                } catch { print("MODEL_DOWNLOAD_SMOKE_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--setup-preview") {
            // An isolated window for checking first-run layout without opening the user's library.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Setup-Preview-" + UUID().uuidString)
                let setup = ModelSetup(root: root, customModel: { nil }, usesCustomModel: { false })
                setup.phase = .available
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 590), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Pisya · Подготовка"
                window.contentView = NSHostingView(rootView: ModelSetupView(setup: setup, onReady: {}).preferredColorScheme(.light))
                window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
                app.run()
            }
            return
        }
        if CommandLine.arguments.contains("--live-pipeline-test") {
            Task { @MainActor in
                do { try await LivePipelineTests.run(); exit(0) }
                catch { print("LIVE_PIPELINE_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--speech-pipeline-test") {
            Task { @MainActor in
                do { try await AudioPipelineTests.runSpeech(); exit(0) }
                catch { print("SPEECH_PIPELINE_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--audio-pipeline-test") {
            Task {
                do { try await AudioPipelineTests.run(); exit(0) }
                catch { print("AUDIO_PIPELINE_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--echo-regression-test") {
            Task {
                do { try await EchoRegressionTests.run(); exit(0) }
                catch { print("ECHO_REGRESSION_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--echo-diagnostics") {
            Task {
                do { try await EchoDiagnostics.run(); exit(0) }
                catch { print("ECHO_DIAGNOSTICS_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--audio-diagnostics") {
            do { try AudioDiagnostics.run(); exit(0) } catch { print("AUDIO_DIAGNOSTICS_FAILED", error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--library-self-test") {
            Task { @MainActor in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                do {
                    func check(_ condition: Bool, _ message: String) throws { if !condition { throw PisyaError.message(message) } }
                    let state = AppState(rootURL: root)
                    var m = Meeting(title: "Fixture", source: "Synthetic"); m.status = .ready
                    let filename = "fixture-mic.caf"
                    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
                    buffer.frameLength = 64000
                    for i in 0..<64000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.1) * 0.2) }
                    do { let file = try AVAudioFile(forWriting: state.library.audioURL(filename), settings: format.settings); try file.write(from: buffer); file.close() }
                    let echoURL = try state.library.audioURL("fixture-remote.caf")
                    do { let file = try AVAudioFile(forWriting: echoURL, settings: format.settings); try file.write(from: buffer); file.close() }
                    let mic = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0] + 16000, count: 32000)).map { $0 * 0.4 }
                    try check(EchoReference(url: echoURL, offset: 0).matches(mic, at: 1), "Echo reference alignment/read failed")
                    try check(!EchoReference(url: echoURL, offset: 2).matches(mic, at: 0), "Echo boundary must retain speech")
                    m.audioFiles = [filename]
                    var segment = TranscriptSegment(start: 0, end: 4, speaker: "Я", text: "Fixture")
                    segment.embedding = [1, 0]; m.segments = [segment]; state.update(m)
                    state.assignVoice(meetingID: m.id, segmentID: segment.id, name: "First", allMatching: true, remember: true)
                    try check(state.meetings[0].segments[0].audioFile == filename, "Source track lost")
                    state.assignVoice(meetingID: m.id, segmentID: segment.id, name: "Corrected", allMatching: false, remember: true)
                    try check(VoiceMatcher.identify([1, 0], profiles: state.voiceProfiles) == "Corrected", "Old profile retained wrong sample")
                    let example = state.voiceProfiles.first { $0.name == "Corrected" }!.examples!.first!
                    let clipURL = root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file)
                    let clip = try AVAudioFile(forReading: clipURL)
                    try check(clip.length == 64000, "Voice clip frame count incorrect: \(clip.length)")
                    state.saveFolder("Folder")
                    let folder = state.folders[0]
                    state.move(state.meetings[0], to: folder.id)
                    try check(state.meetings[0].folderID == folder.id, "Move failed")
                    state.trash(state.meetings[0])
                    try check(try state.library.all().isEmpty, "Trash leaked into library")
                    state.trash(state.meetings[0], restore: true)
                    state.removeFolder(folder)
                    try check(state.meetings[0].folderID == nil, "Folder removal lost record")
                    state.deleteAudio(state.meetings[0])
                    try check(FileManager.default.fileExists(atPath: clipURL.path), "Voice example removed with meeting audio")
                    try check(try state.library.voices().contains { $0.name == "Corrected" }, "Voice profile not persisted")
                    print("LIBRARY_SELF_TEST_OK voice_clip correction source_track folders trash restore echo_reference")
                    exit(0)
                } catch { print("LIBRARY_SELF_TEST_FAILED \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--self-test") {
            Task {
                do {
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisya")
                    let model = root.appendingPathComponent("Models/Qwen3-ASR")
                    let audio = root.appendingPathComponent("smoke.wav")
                    let segments = try await Transcriber().transcribe(files: [(audio, 0)], modelDirectory: model, context: "", speakerDirectory: root.appendingPathComponent("Models/Speakers"), profiles: []) { _, _ in }
                    guard !segments.isEmpty else { throw PisyaError.message("No transcription returned") }
                    try JSONEncoder().encode(segments).write(to: root.appendingPathComponent("smoke-result.json"), options: .atomic)
                    print("SELF_TEST_OK segments=\(segments.count)")
                    exit(0)
                } catch { print("SELF_TEST_FAILED \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        } else { PisyaApp.main() }
    }
}
