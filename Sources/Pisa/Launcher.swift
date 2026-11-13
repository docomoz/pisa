import Foundation
import AppKit
import AVFoundation
import SwiftUI

@main
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--install-models") {
            Task {
                do {
                    guard let manifest = Bundle.main.url(forResource: "models", withExtension: "json") else { throw ModelInstallError.invalidManifest }
                    let assets = try JSONDecoder().decode([ModelAsset].self, from: Data(contentsOf: manifest))
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa/Models")
                    try await ModelInstaller(root: root, assets: assets).install { value in
                        if value.verifying { print("Verifying", value.path) }
                    }
                    print("MODEL_INSTALL_OK"); exit(0)
                } catch { print("MODEL_INSTALL_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--dictionary-self-test") {
            MainActor.assumeIsolated {
                do { try VocabularyDictionaryPreview.test(); print("DICTIONARY_SELF_TEST_OK"); exit(0) }
                catch { print("DICTIONARY_SELF_TEST_FAILED", error.localizedDescription); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--dictionary-preview") || Bundle.main.object(forInfoDictionaryKey: "PisaDictionaryPreview") as? Bool == true {
            MainActor.assumeIsolated { VocabularyDictionaryPreview.run() }
            return
        }
        if CommandLine.arguments.contains("--source-link-self-test") {
            MainActor.assumeIsolated {
                do { try SourceLinkPreview.test(); print("SOURCE_LINK_TEST_OK"); exit(0) }
                catch { print("SOURCE_LINK_TEST_FAILED", error.localizedDescription); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--source-link-preview") || Bundle.main.object(forInfoDictionaryKey: "PisaSourceLinkPreview") as? Bool == true {
            MainActor.assumeIsolated {
                do { try SourceLinkPreview.run() }
                catch { print("SOURCE_LINK_PREVIEW_FAILED", error.localizedDescription) }
            }
            return
        }
        if CommandLine.arguments.contains("--recognition-meeting-preview") {
            do { try RecognitionMeetingPreview.run(); exit(0) }
            catch { print("RECOGNITION_PREVIEW_FAILED", error.localizedDescription); exit(1) }
        }
        if CommandLine.arguments.contains("--recognition-meeting-benchmark") {
            Task {
                do { try await RecognitionMeetingBenchmark.run(); exit(0) }
                catch { print("RECOGNITION_MEETING_BENCHMARK_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--recognition-quality-test") {
            Task { @MainActor in
                do { try await RecognitionQualityTests.run(); exit(0) }
                catch { print("RECOGNITION_QUALITY_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--title-inference-smoke-test") {
            Task { @MainActor in
                do { try await MeetingTitleTests.smoke(); exit(0) }
                catch { print("TITLE_INFERENCE_SMOKE_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--meeting-title-self-test") {
            Task { @MainActor in
                do { try await MeetingTitleTests.run(); exit(0) }
                catch { print("MEETING_TITLES_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--meeting-title-preview") {
            MainActor.assumeIsolated {
                do { try MeetingTitleTests.preview() }
                catch { print("MEETING_TITLES_PREVIEW_FAILED", error.localizedDescription) }
            }
            return
        }
        if CommandLine.arguments.contains("--queue-self-test") {
            Task { @MainActor in
                do {
                    try InterfacePreview.testQueue()
                    try InterfacePreview.testTrashQueuedRecording()
                    try await InterfacePreview.testQueuedTurboTranscription()
                    try await InterfacePreview.testQueuedResumeWithProtectedMetadata()
                    try await InterfacePreview.testTranscriptionDuringRecording()
                    print("QUEUE_TEST_OK"); exit(0)
                }
                catch { print("QUEUE_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--interface-layout-self-test") {
            MainActor.assumeIsolated { exit(InterfaceLayoutTests.run()) }
        }
        if CommandLine.arguments.contains("--trash-self-test") {
            MainActor.assumeIsolated {
                do { try InterfacePreview.testTrashActions(); print("TRASH_TEST_OK"); exit(0) }
                catch { print("TRASH_TEST_FAILED", error.localizedDescription); exit(1) }
            }
        }
        if CommandLine.arguments.contains("--interface-preview") {
            MainActor.assumeIsolated {
                do { try InterfacePreview.run() }
                catch { print("INTERFACE_PREVIEW_FAILED", error.localizedDescription) }
            }
            return
        }
        if CommandLine.arguments.contains("--term-review-self-test") {
            Task { @MainActor in
                do { try TermReviewTests.run(); exit(0) }
                catch { print("TERM_REVIEW_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--term-review-preview") || CommandLine.arguments.contains("--term-dictionary-preview") {
            MainActor.assumeIsolated {
                do { try TermReviewTests.preview(dictionary: CommandLine.arguments.contains("--term-dictionary-preview")) }
                catch { print("TERM_REVIEW_PREVIEW_FAILED", error.localizedDescription) }
            }
            return
        }
        if CommandLine.arguments.contains("--voice-profiles-self-test") {
            Task { @MainActor in
                do { try await VoiceProfileTests.run(); exit(0) }
                catch { print("VOICE_PROFILES_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--voices-preview") {
            MainActor.assumeIsolated {
                do { try VoiceProfileTests.preview() }
                catch { print("VOICE_PREVIEW_FAILED", error.localizedDescription) }
            }
            return
        }
        if CommandLine.arguments.contains("--vocabulary-test") {
            Task { @MainActor in
                do { try await AudioPipelineTests.runVocabulary(); exit(0) }
                catch { print("VOCABULARY_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--capture-self-test") {
            Task { @MainActor in
                do { try await AudioCaptureTests.run(); exit(0) }
                catch { print("CAPTURE_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--model-setup-self-test") {
            Task { @MainActor in
                do { try await ModelSetupTests.run(); exit(0) }
                catch { print("MODEL_SETUP_TEST_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--model-download-smoke-test") {
            Task { @MainActor in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Model-Smoke-" + UUID().uuidString)
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
                    guard setup.ready else { throw PisaError.message(setup.error ?? "Model setup did not become ready") }
                    let ready = try await ModelInstaller(root: root, assets: [small]).isReady()
                    guard ready else { throw PisaError.message("Downloaded model did not verify") }
                    print("MODEL_DOWNLOAD_SMOKE_OK native_https sandbox sha256 live_readiness")
                    exit(0)
                } catch { print("MODEL_DOWNLOAD_SMOKE_FAILED", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--settings-preview") {
            // Check settings against a disposable library without changing the user's access choices.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Settings-Preview-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let state = AppState(rootURL: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Pisa · Настройки"
                window.contentView = NSHostingView(rootView: SettingsView().environmentObject(state).preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU")))
                window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
                app.run()
            }
            return
        }
        if CommandLine.arguments.contains("--setup-preview") {
            // An isolated window for checking first-run layout without opening the user's library.
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                app.setActivationPolicy(.regular)
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Setup-Preview-" + UUID().uuidString)
                let setup = ModelSetup(root: root, customModel: { nil }, usesCustomModel: { false })
                setup.phase = .available
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 590), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Pisa · Подготовка"
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
                    func check(_ condition: Bool, _ message: String) throws { if !condition { throw PisaError.message(message) } }
                    var state = AppState(rootURL: root)
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
                    await state.assignVoice(meetingID: m.id, segmentID: segment.id, name: "First",
                                      allMatching: true, remember: true, extractEmbedding: { _ in [1, 0] })
                    try check(state.meetings[0].segments[0].audioFile == filename, "Source track lost")
                    await state.assignVoice(meetingID: m.id, segmentID: segment.id, name: "Corrected",
                                      allMatching: false, remember: true, extractEmbedding: { _ in [1, 0] })
                    try check(VoiceMatcher.identify([1, 0], profiles: state.voiceProfiles) == "Corrected", "Old profile retained wrong sample")
                    let example = state.voiceProfiles.first { $0.name == "Corrected" }!.examples!.first!
                    let clipURL = root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file)
                    let clip = try AVAudioFile(forReading: clipURL)
                    try check(clip.length == 64000, "Voice clip frame count incorrect: \(clip.length)")
                    state.saveFolder("Folder")
                    let folder = state.folders[0]
                    // A library copied from another Mac can carry an unusable export bookmark.
                    let copiedBookmark = Data("unresolvable export bookmark".utf8)
                    let exportFolder = root.appendingPathComponent("Export", isDirectory: true)
                    try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
                    state.preferences.exportBookmark = copiedBookmark
                    state.preferences.exportDisplayPath = exportFolder.path
                    try state.library.savePreferences(state.preferences)
                    state = AppState(rootURL: root)
                    try check(state.message == nil, "Opening the copied library showed an export alert")
                    try check(state.exportFolderUnavailable, "The copied export bookmark was not marked unavailable")
                    state.move(state.meetings[0], to: folder.id)
                    try check(state.meetings[0].folderID == folder.id, "Move failed")
                    try check(try state.library.read(m.id).folderID == folder.id, "Move was not saved")
                    try check(state.message == nil, "Moving with a copied bookmark triggered auto-export: \(state.message ?? "")")

                    for name in ["New speaker", "Corrected speaker"] {
                        await state.assignVoice(meetingID: m.id, segmentID: segment.id, name: name, allMatching: false, remember: false)
                        try check(try state.library.read(m.id).segments.first?.speaker == name, "Voice correction was not saved")
                        try check(state.message == nil, "A copied export bookmark interrupted voice correction")
                    }
                    try check(try FileManager.default.contentsOfDirectory(atPath: exportFolder.path).isEmpty, "Export wrote to the display path without a bookmark")
                    try check(try state.library.preferences().exportBookmark == copiedBookmark, "Auto-export discarded the saved setting")
                    try state.setExportFolder(exportFolder)
                    state = AppState(rootURL: root)
                    try check(!state.exportFolderUnavailable, "Selecting a folder did not restore auto-export after reopening")
                    await state.assignVoice(meetingID: m.id, segmentID: segment.id, name: "Exported speaker", allMatching: false, remember: false)
                    try check(state.message == nil, "Voice correction failed with a working export folder")
                    let exports = try FileManager.default.subpathsOfDirectory(atPath: exportFolder.path).filter { $0.hasSuffix(".md") }
                    try check(exports.count == 1, "Expected a Markdown file after restoring auto-export")
                    let exported = try String(contentsOf: exportFolder.appendingPathComponent(exports[0]), encoding: .utf8)
                    try check(exported.contains("· Exported speaker**"), "Markdown did not include the new speaker")
                    state.disableExportFolder()
                    try check(try state.library.preferences().exportBookmark == nil, "Turning off auto-export did not persist")
                    let second = state.saveFolder("Second")!
                    let third = state.saveFolder("Third")!
                    state.openFolder(folder.id)
                    state.reorderFolder(folder.id, relativeTo: third, after: true)
                    try check(state.folders.map(\.id) == [second, third, folder.id], "Could not move a folder to the end")
                    state.reorderFolder(third, relativeTo: second, after: false)
                    state.reorderFolder(third, relativeTo: third, after: true)
                    state.reorderFolder(third, relativeTo: UUID(), after: false)
                    try check(state.folders.map(\.id) == [third, second, folder.id], "Invalid drop changed folder order")
                    try check(AppState(rootURL: root).folders == state.folders, "Folder order was not restored")
                    try check(state.folderFilter == folder.id && state.selection == m.id, "Folder reordering changed selection")
                    state.trash(state.meetings[0])
                    try check(try state.library.all().isEmpty, "Trash leaked into library")
                    state.trash(state.meetings[0], restore: true)
                    state.removeFolder(folder)
                    try check(state.meetings[0].folderID == nil, "Folder removal lost record")
                    state.deleteAudio(state.meetings[0])
                    try check(FileManager.default.fileExists(atPath: clipURL.path), "Voice example removed with meeting audio")
                    try check(try state.library.voices().contains { $0.name == "Corrected" }, "Voice profile not persisted")
                    var automaticMeeting = Meeting(title: "Automatic sample", source: "Synthetic")
                    automaticMeeting.status = .ready
                    let automaticFile = "automatic-remote.caf"
                    let longBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
                    longBuffer.frameLength = 192000
                    for i in 0..<192000 { longBuffer.floatChannelData![0][i] = Float(i) / 192000 * 0.2 }
                    do { let file = try AVAudioFile(forWriting: state.library.audioURL(automaticFile), settings: format.settings); try file.write(from: longBuffer); file.close() }
                    automaticMeeting.audioFiles = [automaticFile]; automaticMeeting.audioOffsets = [automaticFile: 10]
                    let short = TranscriptSegment(start: 10, end: 11, speaker: "Участник", text: "Да")
                    var long = TranscriptSegment(start: 11, end: 22, speaker: "Участник", text: "Длинный образец")
                    long.embedding = [0, 1]; automaticMeeting.segments = [short, long]; state.update(automaticMeeting)
                    await state.assignVoice(meetingID: automaticMeeting.id, segmentID: short.id, name: "Automatic", allMatching: true, remember: true)
                    try check(!state.voiceProfiles.contains { $0.name == "Automatic" }, "All-replies correction enrolled an unselected reply")
                    try check(state.meetings.first { $0.id == automaticMeeting.id }?.segments.map(\.speaker) == ["Участник", "Участник"], "Failed enrollment partially changed the transcript")
                    await state.assignVoice(meetingID: automaticMeeting.id, segmentID: long.id, name: "Automatic", allMatching: true, remember: true) { samples in
                        try check(samples.count == 128000, "Extractor did not receive eight seconds")
                        try check(abs(samples[0] - Float(16000) / 192000 * 0.2) < 0.00001, "Extractor received audio outside the preview")
                        return [0, -1]
                    }
                    guard let automaticExample = state.voiceProfiles.first(where: { $0.name == "Automatic" })?.examples?.last else { throw PisaError.message("Selected reply was not saved") }
                    try check(automaticExample.segmentID == long.id, "Saved a different reply from the one selected")
                    try check(automaticExample.embedding == [0, -1] && !automaticExample.needsEmbeddingRefresh, "Saved the transcript embedding instead of the clip embedding")
                    let automaticClip = try AVAudioFile(forReading: root.appendingPathComponent("VoiceSamples").appendingPathComponent(automaticExample.file))
                    try check(automaticClip.length == 128000, "Automatic sample must contain eight seconds")
                    let automaticPCM = try PCMRead.exact(automaticClip, frames: 128000)
                    try check(abs(automaticPCM.floatChannelData![0][0] - Float(16000) / 192000 * 0.2) < 0.00001, "Saved clip ignored the preview range or track offset")
                    await state.assignVoice(meetingID: automaticMeeting.id, segmentID: short.id, name: "Must not save", allMatching: false, remember: true)
                    try check(state.meetings.first { $0.id == automaticMeeting.id }?.segments.first?.speaker == "Automatic", "Missing sample partially changed the speaker")
                    try check(!state.voiceProfiles.contains { $0.name == "Must not save" }, "Single-reply correction learned another reply")
                    await state.assignVoice(meetingID: automaticMeeting.id, segmentID: short.id, name: "Only this reply", allMatching: false, remember: false)
                    let renamed = state.meetings.first { $0.id == automaticMeeting.id }!
                    try check(renamed.segments.map(\.speaker) == ["Only this reply", "Automatic"], "Naming without a usable sample failed")
                    try check(try state.library.voices().contains { $0.name == "Automatic" }, "Automatic voice was not persisted")
                    print("LIBRARY_SELF_TEST_OK voice_clip correction source_track folders folder_order trash restore echo_reference selected_sample clip_embedding track_offset single_reply")
                    exit(0)
                } catch { print("LIBRARY_SELF_TEST_FAILED \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        } else if CommandLine.arguments.contains("--self-test") {
            Task {
                do {
                    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pisa")
                    let model = root.appendingPathComponent("Models/Qwen3-ASR")
                    let audio = root.appendingPathComponent("smoke.wav")
                    let segments = try await Transcriber().transcribe(files: [(audio, 0)], modelDirectory: model, context: "", speakerDirectory: root.appendingPathComponent("Models/Speakers"), profiles: []) { _, _ in }
                    guard !segments.isEmpty else { throw PisaError.message("No transcription returned") }
                    try JSONEncoder().encode(segments).write(to: root.appendingPathComponent("smoke-result.json"), options: .atomic)
                    print("SELF_TEST_OK segments=\(segments.count)")
                    exit(0)
                } catch { print("SELF_TEST_FAILED \(error.localizedDescription)"); exit(1) }
            }
            dispatchMain()
        } else if Bundle.main.object(forInfoDictionaryKey: "PisaInterfacePreview") as? Bool == true {
            // Finder preview copies still open the preview, but explicit diagnostics
            // above must run against the same binary instead of being intercepted.
            MainActor.assumeIsolated {
                do { try InterfacePreview.run() }
                catch { print("INTERFACE_PREVIEW_FAILED", error.localizedDescription) }
            }
        } else { PisaApp.main() }
    }
}
