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
        let newName = "Новое имя"
        let audioName = "meeting-audio.caf"
        let audioURL = try state.library.audioURL(audioName)
        let audio = try Data(contentsOf: root.appendingPathComponent("VoiceSamples").appendingPathComponent(original.examples![0].file))
        try audio.write(to: audioURL)
        var active = Meeting(title: "Сохранённая встреча", source: "Проверка")
        active.status = .ready
        active.notes = "\(original.name) упомянута в заметках"
        active.audioFiles = [audioName]
        active.audioOffsets = [audioName: 1]
        active.segments = [
            TranscriptSegment(start: 1, end: 2, speaker: original.name, text: "Меня зовут \(original.name)"),
            TranscriptSegment(start: 2, end: 3, speaker: other.name, text: "Добрый день"),
            TranscriptSegment(start: 3, end: 4, speaker: original.name, text: "Начинаем"),
            TranscriptSegment(start: 4, end: 5, speaker: "\(original.name) Петрова", text: "Хорошо"),
        ]
        for index in active.segments.indices { active.segments[index].audioFile = audioName }
        active.segments[0].embedding = original.samples[0]
        state.update(active)
        var trashed = Meeting(title: "Встреча в корзине", source: "Проверка")
        trashed.status = .ready
        trashed.deletedAt = Date()
        trashed.segments = [TranscriptSegment(start: 0, end: 3, speaker: original.name, text: "Встреча завершилась")]
        state.update(trashed)
        var unrelated = Meeting(title: "Другая встреча", source: "Проверка")
        unrelated.status = .ready
        unrelated.segments = [TranscriptSegment(start: 0, end: 2, speaker: original.name.uppercased(), text: "Другое имя говорящего")]
        state.update(unrelated)
        var expectedActive = active
        expectedActive.segments[0].speaker = newName
        expectedActive.segments[2].speaker = newName
        var expectedTrashed = trashed
        expectedTrashed.segments[0].speaker = newName

        func check(_ value: Bool, _ message: String) throws {
            if !value { throw PisyaError.message(message) }
        }
        func checkTranscripts(in state: AppState) throws {
            for expected in [expectedActive, expectedTrashed, unrelated] {
                try check(state.meetings.first { $0.id == expected.id } == expected, "Incorrect in-memory transcript after rename: \(expected.title)")
                try check(try state.library.read(expected.id) == expected, "Incorrect saved transcript after rename: \(expected.title)")
            }
            try check(try Data(contentsOf: audioURL) == audio, "Rename changed meeting audio")
        }

        try state.renameVoice(original.id, to: "  Новое имя \n")
        try checkTranscripts(in: state)
        try check(state.voiceProfiles[0].name == newName, "Rename must trim and update the saved voice")
        let renamed = try state.library.voices()[0]
        try check(renamed.id == original.id && renamed.name == newName, "Rename must persist the same profile")
        try check(renamed.samples == original.samples && renamed.examples?.map(\.file) == original.examples?.map(\.file), "Rename changed training data")
        try check(VoiceMatcher.identify([1, 0], profiles: state.voiceProfiles) == newName, "Recognition still uses the old name")
        state.search = newName
        try check(state.filtered.map(\.id) == [active.id], "Search did not index the new active transcript label")
        state.showingTrash = true
        try check(state.filtered.map(\.id) == [trashed.id], "Search did not index the new trashed transcript label")
        state.search = original.name
        try check(state.filtered.isEmpty, "Search still indexes the old trashed transcript label")
        state.showingTrash = false
        state.search = ""
        for invalid in [" \n", other.name.uppercased()] {
            var rejected = false
            do { try state.renameVoice(original.id, to: invalid) } catch { rejected = true }
            try check(rejected && state.voiceProfiles[0].name == newName, "Invalid rename was accepted")
            try checkTranscripts(in: state)
        }
        let voicesURL = root.appendingPathComponent("voices.json")
        let backupURL = root.appendingPathComponent("voices-backup.json")
        let persistedVoices = try Data(contentsOf: voicesURL)
        try FileManager.default.moveItem(at: voicesURL, to: backupURL)
        try FileManager.default.createDirectory(at: voicesURL, withIntermediateDirectories: false)
        var renameFailed = false
        do { try state.renameVoice(original.id, to: "Не сохранено") } catch { renameFailed = true }
        try check(renameFailed && state.voiceProfiles[0].name == newName, "Failed save changed the profile in memory")
        try checkTranscripts(in: state)
        var deleteFailed = false
        do { try state.forgetVoice(original.id) } catch { deleteFailed = true }
        try check(deleteFailed && state.voiceProfiles.count == 2, "Failed delete changed the saved profiles")
        for example in original.examples ?? [] {
            try check(FileManager.default.fileExists(atPath: root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file).path), "Failed save removed a voice example")
        }
        try FileManager.default.removeItem(at: voicesURL)
        try FileManager.default.moveItem(at: backupURL, to: voicesURL)
        try check(try Data(contentsOf: voicesURL) == persistedVoices, "Failed save changed the persisted profiles")
        let originalSegment = active.segments[0]
        let correctedText = "Исправленная реплика"
        state.editSegmentText(correctedText, from: originalSegment, meetingID: active.id)
        expectedActive.segments[0].text = correctedText
        try checkTranscripts(in: state)
        // An unchanged draft must preserve a newer edit saved after the draft was opened.
        state.editSegmentText(originalSegment.text, from: originalSegment, meetingID: active.id)
        try checkTranscripts(in: state)
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
        try checkTranscripts(in: state)
        let restarted = AppState(rootURL: root)
        try check(restarted.voiceProfiles.map(\.id) == [other.id], "Forgotten voice returned after restart")
        try checkTranscripts(in: restarted)

        var selfMeeting = Meeting(title: "Микрофон", source: "Проверка")
        selfMeeting.audioFiles = ["test-mic.caf", "test-remote.caf"]
        selfMeeting.segments = [
            TranscriptSegment(start: 0, end: 3, speaker: "Я", text: "Образец"),
            TranscriptSegment(start: 3, end: 6, speaker: "Я", text: "Обычная метка микрофона"),
            TranscriptSegment(start: 6, end: 9, speaker: "Я", text: "Узнанный голос с другой дорожки"),
        ]
        selfMeeting.segments[2].audioFile = "test-remote.caf"
        selfMeeting.segments[2].embedding = [1, 0]
        restarted.update(selfMeeting)
        var selfProfile = VoiceProfile(name: "Я", samples: [[1, 0]])
        selfProfile.examples = [VoiceExample(file: "example.caf", meetingID: selfMeeting.id,
                                             segmentID: selfMeeting.segments[0].id, embedding: [1, 0])]
        restarted.voiceProfiles.append(selfProfile)
        try restarted.library.saveVoices(restarted.voiceProfiles)
        try restarted.renameVoice(selfProfile.id, to: "Ведущий")
        let selfSegments = try restarted.library.read(selfMeeting.id).segments
        try check(selfSegments.map(\.speaker) == ["Ведущий", "Я", "Ведущий"], "Rename did not distinguish a voice from a generic microphone label")
        try check(selfSegments[0].audioFile == "test-mic.caf", "Rename changed the selected audio track")
        print("VOICE_PROFILES_TEST_OK rename trim duplicate empty persistence failure_atomicity playback stop delete_examples preserve_other_voice rename_transcripts search restart stale_editor generic_label")
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
