import AppKit
import SwiftUI

@MainActor
enum TermReviewTests {
    private static func fixture(_ state: AppState, segmentCount: Int = 18) throws -> Meeting {
        state.preferences.vocabulary = "Сбер"
        if segmentCount > 18 {
            let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            let terms = (0..<96).map { "ТЕСТ" + String(letters[$0 / 26]) + String(letters[$0 % 26]) }
            state.preferences.vocabulary += "\n" + terms.joined(separator: "\n")
        }
        state.preferences.automaticRecording = false
        try state.library.savePreferences(state.preferences)
        var meeting = Meeting(title: "Обсуждение терминов", source: "Проверка интерфейса")
        meeting.status = .ready
        meeting.duration = Double(segmentCount * 20)
        let forms = ["2ГИС'а", "2ГИС'е", "2ГИС'ом"]
        let misspellings = ["ЛПДов", "ЛПДом", "ЛПД"]
        meeting.segments = (0..<segmentCount).map { index in
            let name = index.isMultiple(of: 2) ? "Куделька" : "куделька"
            let nameContext = index < 4 ? " Обсудили проект \(name)." : ""
            let text = "Обсудили обновление \(forms[index % forms.count]) и проверили MapKit, Qwen3-ASR и LLM'ки. "
                + "В расшифровке встретилось (\(misspellings[index % misspellings.count])). "
                + "Длинный контекст помогает проверить переносы текста и прокрутку списка вхождений до последней реплики.\(nameContext)"
            return TranscriptSegment(start: Double(index * 20), end: Double(index * 20 + 18),
                                     speaker: index.isMultiple(of: 2) ? "Анна" : "Борис",
                                     text: text)
        }
        meeting.segments[0].text += " Обсудили с Димой планы для Москвы и России. Для ЛПР, ЛПР'ов, ЛПРов и ЛПРы обсудили запрос Сбера и встречу со Сбером."
        meeting.segments[1].text += " Так, Давайте обсудим Семь задач и Новогодний график. Ну, Во-первых, что-то и как-то. Потом снова что-то и как-то."
        state.update(meeting)
        return try state.library.read(meeting.id)
    }

    private static func technologyFixture(_ state: AppState) throws -> Meeting {
        state.preferences.vocabulary = ""
        state.preferences.automaticRecording = false
        try state.library.savePreferences(state.preferences)
        var meeting = Meeting(title: "Встроенные термины", source: "Проверка словаря")
        meeting.status = .ready
        meeting.segments = [TranscriptSegment(start: 0, end: 7, speaker: "Участник",
            text: "🎙 С битуби работали вчера. Обсудили с Б2Б'ом и проверили B2B. «битуби» было в цитате."),
            TranscriptSegment(start: 8, end: 17, speaker: "Участник",
                text: "Для пи ар ди сверили API. О документации договорились с представителями компании Apple.")]
        state.update(meeting)
        return try state.library.read(meeting.id)
    }

    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Term-Review-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        let original = try fixture(state)
        func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw PisaError.message(message) }
        }
        let file = state.library.meetingsDirectory.appendingPathComponent(original.id.uuidString + ".json")
        let originalData = try Data(contentsOf: file)
        let occurrences = TranscriptTerms.matches("2ГИС", in: original.segments, vocabulary: state.preferences.vocabulary)
        try check(occurrences.count == 18, "Family search did not include all endings")
        let candidates = TranscriptTerms.candidates(in: original.segments, vocabulary: state.preferences.vocabulary)
        try check(candidates.contains { $0.text == "2ГИС" && $0.occurrences.count == 18 }, "Family candidate was not grouped")
        try check(candidates.contains { $0.text == "ЛПР" && $0.occurrences.count == 4 }, "Cyrillic family candidate was not grouped")
        let candidateTexts = Set(candidates.map(\.text))
        try check(candidateTexts.isDisjoint(with: ["Сбер", "Сбера", "Сбером"]), "Known dictionary forms appeared as candidates")
        try check(Set(["MapKit", "Qwen3-ASR", "LLM"]).isSubset(of: candidateTexts), "Candidate list dropped a term")
        try check(candidateTexts.isDisjoint(with: ["Димой", "Москвы", "России"]), "Candidate list included a person or a place")
        try check(candidateTexts.isDisjoint(with: ["Давайте", "Семь", "Новогодний", "Во-первых", "что-то", "как-то"]),
                  "Candidate list included ordinary Russian words")
        try check(TranscriptTerms.matches("Москвы", in: original.segments).count == 1, "Manual search did not find a place name")

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

        let cyrillic = TranscriptTerms.matches("ЛПР", in: original.segments, vocabulary: state.preferences.vocabulary)
        try state.replaceTerms(cyrillic, with: "ЛПР", meetingID: original.id)
        let corrected = try state.library.read(original.id)
        try check(corrected.segments[0].text.contains("Для ЛПР, ЛПР'ов, ЛПР'ов и ЛПР'ы"), "Cyrillic endings were not corrected")
        try check(corrected.segments[0].text.contains("запрос Сбера и встречу со Сбером"), "Dictionary forms changed in the transcript")
        try state.undoTermReplacement(meetingID: original.id)

        let misspellings = TranscriptTerms.matches("ЛПД", in: original.segments, vocabulary: state.preferences.vocabulary)
        try check(misspellings.count == 18, "Cyrillic family search did not include all endings")
        try state.replaceTerms(misspellings, with: "ЛПР'ов", meetingID: original.id)
        let apostrophizedEdit = try state.library.read(original.id)
        let correctedForms = ["ЛПР'ов", "ЛПР'ом", "ЛПР"]
        let expectedEdit = original.segments.enumerated().map { index, segment in
            let misspelling = misspellings[index].text
            let spelling = correctedForms[index % correctedForms.count]
            return segment.text.replacingOccurrences(of: "(\(misspelling))", with: "(\(spelling))")
        }
        try check(apostrophizedEdit.segments.map(\.text) == expectedEdit,
                  "Saved Cyrillic replacement lost the apostrophe or changed an ending")
        try state.undoTermReplacement(meetingID: original.id)

        try state.addRecognitionTerm("2ГИС'ом")
        try check(state.preferences.vocabulary == "Сбер\n2ГИС", "Dictionary saved an inflected form")
        try check(try state.library.preferences().vocabulary == "Сбер\n2ГИС", "Dictionary base was not persisted")
        var duplicateRejected = false
        do { try state.addRecognitionTerm("2ГИС'е") } catch { duplicateRejected = true }
        try check(duplicateRejected && state.preferences.vocabulary == "Сбер\n2ГИС", "Dictionary added another form of the same base")
        let restarted = AppState(rootURL: root)
        try check(restarted.preferences.vocabulary == "Сбер\n2ГИС", "Dictionary base changed after restart")
        try check(restarted.meetings.first { $0.id == original.id }?.segments == original.segments, "Restored transcript changed after restart")

        let builtInMeeting = try technologyFixture(state)
        let builtIn = TranscriptTerms.candidates(in: builtInMeeting.segments, vocabulary: state.preferences.vocabulary)
        let business = try unwrap(builtIn.first { $0.text == "B2B" }, "Built-in term missing from empty-vocabulary meeting")
        try check(business.occurrences.map(\.text) == ["битуби", "Б2Б'ом", "B2B"], "Built-in candidate spans were not grouped")
        try state.replaceTerms(business.occurrences, with: "B2B", meetingID: builtInMeeting.id)
        try check(try state.library.read(builtInMeeting.id).segments[0].text ==
            "🎙 С B2B работали вчера. Обсудили с B2B'ом и проверили B2B. «битуби» было в цитате.",
            "Built-in term replacement changed surrounding text or lost a spoken ending")
        try state.undoTermReplacement(meetingID: builtInMeeting.id)
        try check(try state.library.read(builtInMeeting.id).segments == builtInMeeting.segments, "Built-in replacement could not be undone")
        try check(try state.library.preferences().vocabulary.isEmpty, "Built-in terms changed personal dictionary")
        try state.addRecognitionTerm("B2B")
        try check(try state.library.preferences().vocabulary == "B2B", "Explicit manual addition of a built-in term was not saved")
        print("TERM_REVIEW_TEST_OK grouped_family persisted_replacement preserved_endings stale_rejection no_op undo dictionary_base restart built_in_terms")
    }

    private static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw PisaError.message(message) }
        return value
    }

    static func preview(dictionary: Bool = false) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Term-Review-Preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        let segmentCount = CommandLine.arguments.contains("--long-transcript-preview") ? 1_800 : 18
        let meeting = try !dictionary && CommandLine.arguments.contains("--technology-terms-preview")
            ? technologyFixture(state) : fixture(state, segmentCount: segmentCount)
        let large = CommandLine.arguments.contains("--large-text") || CommandLine.arguments.contains("--large-text-preview")
        let entry = !dictionary && CommandLine.arguments.contains("--term-review-entry-preview")
        let content: AnyView
        if dictionary {
            content = AnyView(SettingsView(initialSection: "Словарь"))
        } else if entry {
            state.select(meeting.id)
            content = AnyView(MainView())
        } else {
            content = AnyView(TermReview(meeting: meeting))
        }
        let size = entry ? NSSize(width: 1290, height: 760) : dictionary
            ? NSSize(width: 900, height: 700) : NSSize(width: 940, height: 660)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = dictionary ? "Pisa · Словарь распознавания" : "Pisa · Разметка терминов"
        window.contentView = NSHostingView(rootView: content.environmentObject(state).preferredColorScheme(.light)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.appTextScale, large ? 1.2 : 1)
            .focusEffectDisabled())
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }
}
