import AppKit
import SwiftUI

@MainActor
enum TermReviewTests {
    private static func fixture(_ state: AppState) throws -> Meeting {
        state.preferences.vocabulary = ""
        state.preferences.automaticRecording = false
        try state.library.savePreferences(state.preferences)
        var meeting = Meeting(title: "Обсуждение терминов", source: "Проверка интерфейса")
        meeting.status = .ready
        meeting.duration = 360
        let forms = ["2ГИС'а", "2ГИС'е", "2ГИС'ом"]
        meeting.segments = (0..<18).map { index in
            TranscriptSegment(start: Double(index * 20), end: Double(index * 20 + 18),
                              speaker: index.isMultiple(of: 2) ? "Анна" : "Борис",
                              text: "Обсудили обновление \(forms[index % forms.count]) и проверили MapKit, Qwen3-ASR и LLM'ки. Длинный контекст помогает проверить переносы текста и прокрутку списка вхождений до последней реплики.")
        }
        state.update(meeting)
        return try state.library.read(meeting.id)
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Term-Review-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        let original = try fixture(state)
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw PisyaError.message(message) }
        }
        let file = state.library.meetingsDirectory.appendingPathComponent(original.id.uuidString + ".json")
        let originalData = try Data(contentsOf: file)
        let occurrences = TranscriptTerms.matches("2ГИС", in: original.segments, vocabulary: state.preferences.vocabulary)
        try check(occurrences.count == 18, "Family search did not include all endings")
        try check(TranscriptTerms.candidates(in: original.segments, vocabulary: "").contains { $0.text == "2ГИС" && $0.occurrences.count == 18 }, "Family candidate was not grouped")

        try state.replaceTerms(occurrences, with: "2ГИС", meetingID: original.id)
        try check(try Data(contentsOf: file) == originalData, "No-op replacement rewrote the saved meeting")
        try check(!state.canUndoTermReplacement(meetingID: original.id), "No-op replacement created undo history")

        try state.replaceTerms(occurrences, with: "2GIS", meetingID: original.id)
        let edited = try state.library.read(original.id)
        let expected = original.segments.map { $0.text.replacingOccurrences(of: "2ГИС", with: "2GIS") }
        try check(edited.segments.map(\.text) == expected, "Family replacement lost endings or changed unrelated text")
        try check(state.meetings.first { $0.id == original.id }?.segments == edited.segments, "Persisted replacement differs from memory")
        try check(state.canUndoTermReplacement(meetingID: original.id), "Replacement cannot be undone")

        let editedData = try Data(contentsOf: file)
        var staleRejected = false
        do { try state.replaceTerms(occurrences, with: "GIS", meetingID: original.id) }
        catch { staleRejected = true }
        let staleData = try Data(contentsOf: file)
        try check(staleRejected && staleData == editedData, "Stale replacement changed the saved meeting")
        try check(state.canUndoTermReplacement(meetingID: original.id), "Stale replacement destroyed undo history")

        let current = TranscriptTerms.matches("2GIS", in: edited.segments, vocabulary: "")
        try state.replaceTerms(current, with: "2GIS", meetingID: original.id)
        try check(state.canUndoTermReplacement(meetingID: original.id), "No-op replacement destroyed previous undo history")
        try state.undoTermReplacement(meetingID: original.id)
        try check(try state.library.read(original.id).segments == original.segments, "Undo did not persist the original transcript")
        try check(state.meetings.first { $0.id == original.id }?.segments == original.segments, "Undo did not restore the in-memory transcript")
        try check(!state.canUndoTermReplacement(meetingID: original.id), "Undo history was not consumed")

        try state.addRecognitionTerm("2ГИС'ом")
        try check(state.preferences.vocabulary == "2ГИС", "Dictionary saved an inflected form")
        try check(try state.library.preferences().vocabulary == "2ГИС", "Dictionary base was not persisted")
        var duplicateRejected = false
        do { try state.addRecognitionTerm("2ГИС'е") } catch { duplicateRejected = true }
        try check(duplicateRejected && state.preferences.vocabulary == "2ГИС", "Dictionary added another form of the same base")
        let restarted = AppState(rootURL: root)
        try check(restarted.preferences.vocabulary == "2ГИС", "Dictionary base changed after restart")
        try check(restarted.meetings.first { $0.id == original.id }?.segments == original.segments, "Restored transcript changed after restart")
        print("TERM_REVIEW_TEST_OK grouped_family persisted_replacement preserved_endings stale_rejection no_op undo dictionary_base restart")
    }

    static func preview(dictionary: Bool = false) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Term-Review-Preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        let meeting = try fixture(state)
        let large = CommandLine.arguments.contains("--large-text") || CommandLine.arguments.contains("--large-text-preview")
        let content: AnyView = dictionary
            ? AnyView(SettingsView(initialSection: "Модель"))
            : AnyView(TermReview(meeting: meeting))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: dictionary ? 900 : 940, height: dictionary ? 700 : 660),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = dictionary ? "Pisya · Словарь распознавания" : "Pisya · Разметка терминов"
        window.contentView = NSHostingView(rootView: content.environmentObject(state).preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.appTextScale, large ? 1.2 : 1)
            .focusEffectDisabled())
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }
}
