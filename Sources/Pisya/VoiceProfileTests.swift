import AppKit
import AVFoundation
import SwiftUI

@MainActor
enum VoiceProfileTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Voice-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        try seed(state, count: 2)
        let original = state.voiceProfiles[0]
        let other = state.voiceProfiles[1]
        var active = Meeting(title: "Сохранённая встреча", source: "Проверка")
        active.status = .ready
        active.segments = [TranscriptSegment(start: 0, end: 3, speaker: original.name, text: "Прежнее имя остаётся в расшифровке")]
        state.update(active)
        var trashed = active; trashed.id = UUID(); trashed.deletedAt = Date()
        state.update(trashed)
        let snapshots = try [active, trashed].map { meeting -> (URL, Data) in
            let url = state.library.meetingsDirectory.appendingPathComponent(meeting.id.uuidString + ".json")
            return (url, try Data(contentsOf: url))
        }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw PisyaError.message(message) }
        }
        func unchangedMeetings() throws {
            for (url, data) in snapshots { try check(try Data(contentsOf: url) == data, "A saved transcript was rewritten") }
            try check(state.meetings.allSatisfy { $0.segments[0].speaker == original.name }, "A transcript name changed in memory")
        }
        try state.renameVoice(original.id, to: "  Новое имя \n")
        try check(state.voiceProfiles[0].name == "Новое имя", "Rename must trim and update the saved voice")
        let renamed = try state.library.voices()[0]
        try check(renamed.id == original.id && renamed.name == "Новое имя", "Rename must persist the same profile")
        try check(renamed.samples == original.samples && renamed.examples?.map(\.file) == original.examples?.map(\.file), "Rename changed training data")
        try check(VoiceMatcher.identify([1, 0], profiles: state.voiceProfiles) == "Новое имя", "Recognition still uses the old name")
        try unchangedMeetings()
        for invalid in [" \n", other.name.uppercased()] {
            var rejected = false
            do { try state.renameVoice(original.id, to: invalid) } catch { rejected = true }
            try check(rejected && state.voiceProfiles[0].name == "Новое имя", "Invalid rename was accepted")
        }
        let voicesURL = root.appendingPathComponent("voices.json")
        let backupURL = root.appendingPathComponent("voices-backup.json")
        try FileManager.default.moveItem(at: voicesURL, to: backupURL)
        try FileManager.default.createDirectory(at: voicesURL, withIntermediateDirectories: false)
        var renameFailed = false
        do { try state.renameVoice(original.id, to: "Не сохранено") } catch { renameFailed = true }
        try check(renameFailed && state.voiceProfiles[0].name == "Новое имя", "Failed save changed the profile in memory")
        var deleteFailed = false
        do { try state.forgetVoice(original.id) } catch { deleteFailed = true }
        try check(deleteFailed && state.voiceProfiles.count == 2, "Failed delete changed the saved profiles")
        for example in original.examples ?? [] {
            try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file).path), "Failed save removed a voice example")
        }
        try FileManager.default.removeItem(at: voicesURL)
        try FileManager.default.moveItem(at: backupURL, to: voicesURL)
        let playing = original.examples![0]
        state.playExample(playing)
        try check(state.playingSegmentID == playing.id, "Voice example did not start")
        state.playExample(playing)
        try check(state.playingSegmentID == nil, "Voice example did not stop on second press")
        state.playExample(playing)
        try state.forgetVoice(original.id)
        try check(state.playingSegmentID == nil, "Forgetting a playing voice did not stop playback")
        try check(state.voiceProfiles.map(\.id) == [other.id], "Forgot the wrong saved voice")
        for example in original.examples ?? [] {
            try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file).path), "Forgotten voice example remains on disk")
        }
        for example in other.examples ?? [] {
            try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file).path), "Another voice lost its example")
        }
        try unchangedMeetings()
        let restarted = AppState(rootURL: root)
        try check(restarted.voiceProfiles.map(\.id) == [other.id], "Forgotten voice returned after restart")
        try check(restarted.meetings.allSatisfy { $0.segments[0].speaker == original.name }, "Transcript names changed after restart")
        print("VOICE_PROFILES_TEST_OK rename trim duplicate empty persistence failure_atomicity playback stop delete_examples preserve_other_voice preserve_transcripts restart")
    }

    static func seed(_ state: AppState, count: Int) throws {
        let folder = state.library.root.appendingPathComponent("VoiceSamples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for index in 0..<48000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.08) * 0.025) }
        var profiles: [VoiceProfile] = []
        for index in 0..<count {
            let embedding: [Float] = index == 0 ? [1, 0] : [0, 1]
            var profile = VoiceProfile(name: index == 0 ? "Анна" : index == 1 ? "Борис" : index == 2 ? "Екатерина Александровна с очень длинным именем для проверки переноса в списке сохранённых голосов" : "Участник \(index + 1)", samples: [embedding])
            var examples: [VoiceExample] = []
            for _ in 0..<(index == 0 ? 10 : [1, 2, 0, 4][(index - 1) % 4]) {
                let filename = UUID().uuidString + ".caf"
                let file = try AVAudioFile(forWriting: folder.appendingPathComponent(filename), settings: format.settings)
                try file.write(from: buffer); file.close()
                examples.append(VoiceExample(file: filename, meetingID: UUID(), segmentID: UUID(), embedding: embedding))
            }
            profile.examples = examples
            profiles.append(profile)
        }
        try state.library.saveVoices(profiles); state.voiceProfiles = profiles
    }

    static func preview() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Voices-Preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        if !CommandLine.arguments.contains("--empty") { try seed(state, count: 12) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pisya · Голоса"
        window.contentView = NSHostingView(rootView: SettingsView(initialSection: "Голоса").environmentObject(state).preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.appTextScale, CommandLine.arguments.contains("--large-text-preview") ? 1.2 : 1))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }
}
