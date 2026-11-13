import AppKit
import AVFoundation
import SwiftUI

// Attach passive measurements only when a test host supplies the named space.
enum InterfaceLayoutElement: Hashable {
    case welcomeContent, welcomeTitle, welcomeDescription, welcomeAction
    case mainToolbar, meetingMetadata, meetingTitle, meetingContent, meetingStatus, audioToggle, waveform
    case transcriptSearch, librarySearch, firstMeetingAction, detailsButton
    case setupStatus, setupAction
    case microphoneLabel, systemAudioLabel, microphoneWarning, systemAudioWarning
    case settingsTab(String)
    case dictionarySearch, dictionaryEntry, dictionaryAdd, dictionaryResult, dictionaryEdit
    case termSearch, termFind, termReplacement
    case renameField, folderName, voiceName, voiceSample(UUID), savedVoiceSearch, savedVoiceName, voiceMergeSearch
    case voiceMergeList, voiceMergeCandidate(UUID)
}

private struct InterfaceFrames: PreferenceKey {
    static var defaultValue: [InterfaceLayoutElement: CGRect] { [:] }
    static func reduce(value: inout [InterfaceLayoutElement: CGRect], nextValue: () -> [InterfaceLayoutElement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

extension EnvironmentValues {
    @Entry fileprivate var measuresInterfaceLayout = false
}

extension View {
    func measuredForInterfaceTest(_ element: InterfaceLayoutElement) -> some View {
        modifier(InterfaceMeasurement(element: element))
    }
}

private struct InterfaceMeasurement: ViewModifier {
    @Environment(\.measuresInterfaceLayout) private var enabled
    let element: InterfaceLayoutElement

    func body(content: Content) -> some View {
        content.background {
            if enabled {
                GeometryReader { geometry in
                    Color.clear.preference(key: InterfaceFrames.self,
                                           value: [element: geometry.frame(in: .named("interface-layout-test"))])
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

@MainActor
enum InterfaceLayoutTests {
    static func run() -> Int32 {
        let app = NSApplication.shared
        guard NSScreen.main != nil else {
            fputs("BLOCKED: interface layout checks require a macOS WindowServer session\n", stderr)
            return 77
        }
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Interface-Tests-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let state = AppState(rootURL: root)
            state.modelSetup.phase = .ready
            let suite = LayoutSuite()
            try suite.checkScreens(state: state)
            print("INTERFACE_LAYOUT_TEST_RESULT checks=\(suite.checks) failures=\(suite.failures)")
            return suite.failures == 0 && suite.checks > 0 ? 0 : 1
        } catch {
            fputs("INTERFACE_LAYOUT_TEST_FAILED: \(error)\n", stderr)
            return 1
        }
    }
}

@MainActor
private final class LayoutSuite {
    private(set) var checks = 0
    private(set) var failures = 0
    private var scenario = ""

    private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            fputs("FAIL [\(scenario)] \(message)\n", stderr)
        }
    }

    private func equal(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        check(abs(actual - expected) <= 0.5, "\(message) (actual \(actual), expected \(expected) pt)")
    }

    private func frames(_ elements: [InterfaceLayoutElement], in host: LayoutHost) -> [CGRect]? {
        let ready = host.wait { elements.allSatisfy { host.frames[$0]?.isEmpty == false } }
        check(ready, "rendered \(elements); found \(host.frames.keys)")
        return ready ? elements.compactMap { host.frames[$0] } : nil
    }

    func checkScreens(state: AppState) throws {
        let file = "interface-fixture-mic.caf"
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
              let samples = buffer.floatChannelData?[0] else {
            throw PisaError.message("Could not create the synthetic audio fixture")
        }
        buffer.frameLength = 16_000
        samples.initialize(repeating: 0.05, count: 16_000)
        let writer = try AVAudioFile(forWriting: state.library.audioURL(file), settings: format.settings)
        try writer.write(from: buffer)
        writer.close()

        var ready = Meeting(title: "Проверка планов и результатов", source: "Тестовое аудио")
        ready.status = .ready
        ready.duration = 1
        ready.audioFiles = [file]
        ready.segments = [
            .init(start: 0, end: 1, speaker: "Анна", text: "Обсудили сроки и проверили написание названия Писая.")
        ]
        var saved = Meeting(title: "Сохранённое аудио", source: ready.source)
        saved.duration = ready.duration
        saved.audioFiles = ready.audioFiles
        var queued = saved
        queued.id = UUID()
        queued.title = "Аудио в очереди"
        var processing = saved
        processing.id = UUID()
        processing.title = "Обработка аудио"
        processing.status = .processing
        var interrupted = ready
        interrupted.id = UUID()
        interrupted.title = "Незавершённая расшифровка"
        interrupted.status = .failed
        interrupted.liveCommittedUntil = 0.4
        for meeting in [ready, saved, queued, processing, interrupted] { state.update(meeting) }
        state.processingID = processing.id
        state.phase = "Распознавание"
        state.progress = 0.42
        state.enqueue(queued.id)
        state.preferences.vocabulary = "Писая"

        for (size, scale) in [(CGSize(width: 980, height: 660), 1.0), (CGSize(width: 1200, height: 800), 1.2),
                              (CGSize(width: 1200, height: 800), 1.0), (CGSize(width: 980, height: 660), 1.2)] {
            scenario = "main \(Int(size.width))×\(Int(size.height)), \(Int(scale * 100))%"
            state.select(nil)
            let host = LayoutHost(MainView().environmentObject(state), size: size, scale: scale)
            defer { host.close() }
            checkWelcome(in: host)
            state.select(ready.id)
            guard let reference = checkMeetingHeader(in: host) else { continue }
            checkTranscript(in: host, wide: size.width > 980)

            for (meeting, firstContent) in [(saved, InterfaceLayoutElement.waveform), (queued, .meetingStatus),
                                            (processing, .meetingStatus), (interrupted, .meetingStatus)] {
                scenario = "\(meeting.title) \(Int(size.width))×\(Int(size.height)), \(Int(scale * 100))%"
                state.select(meeting.id)
                host.settle()
                if let title = checkMeetingHeader(in: host) {
                    equal(title.minY, reference.minY, "meeting title keeps its top inset across states")
                    equal(title.minX, reference.minX, "meeting title keeps its left inset across states")
                }
                if let measured = frames([firstContent, .meetingContent], in: host) {
                    let first = measured[0]
                    let content = measured[1]
                    equal(first.minX, content.minX, "first content is aligned to the meeting's left edge")
                    equal(first.minY - content.minY, firstContent == .waveform ? 12 : 0, "first content keeps the intended top spacing")
                    if firstContent == .waveform {
                        equal(first.maxX, content.maxX, "automatic waveform fills the content width")
                    }
                }
            }
        }
        var voiceMeeting = ready
        voiceMeeting.id = UUID()
        voiceMeeting.audioFiles = []
        state.update(voiceMeeting)
        let savedVoice = VoiceProfile(name: "ПППППП", samples: [[1, 0]])
        state.voiceProfiles = [savedVoice]
        for scale in [1.0, 1.1, 1.2] {
            if scale != 1.1 {
                checkSetup(state.modelSetup, scale: scale)
                checkRecordingLevels(state.recordingMonitor, scale: scale)
            }
            checkForms(state: state, meeting: ready, scale: scale)
            checkScreenFields(state: state, meeting: ready, voiceMeeting: voiceMeeting, savedVoice: savedVoice, scale: scale)
        }
    }

    private func checkWelcome(in host: LayoutHost) {
        guard let measured = frames([.welcomeContent, .welcomeTitle, .welcomeDescription, .welcomeAction], in: host) else { return }
        for element in measured.dropFirst() {
            equal(element.midX, measured[0].midX, "welcome heading, description and action share the content center")
            check(element.minX >= measured[0].minX && element.maxX <= measured[0].maxX, "welcome content fits at this window size")
        }
        equal(measured[2].minY - measured[1].maxY, 16, "welcome title-to-description gap")
        equal(measured[3].minY - measured[2].maxY, 24, "welcome description-to-action gap")
    }

    private func checkMeetingHeader(in host: LayoutHost) -> CGRect? {
        if let header = frames([.mainToolbar, .meetingMetadata], in: host) {
            equal(header[1].minY - header[0].maxY, 12, "meeting metadata starts just below the main toolbar")
        }
        guard let measured = frames([.meetingTitle, .meetingContent], in: host) else { return nil }
        equal(measured[1].minY - measured[0].maxY, 16, "single gap below the meeting title")
        equal(measured[0].minX, measured[1].minX, "title and meeting content have the same left edge")
        return measured[0]
    }

    private func checkTranscript(in host: LayoutHost, wide: Bool) {
        let action: InterfaceLayoutElement = wide ? .firstMeetingAction : .detailsButton
        guard let collapsed = frames([.transcriptSearch, action, .meetingContent, .audioToggle], in: host) else { return }
        equal(collapsed[0].minY, collapsed[1].minY, "search and meeting actions start on the same horizontal line")
        equal(collapsed[0].minY, collapsed[2].minY, "search starts directly below the title gap when the player is closed")
        check(host.frames[.waveform] == nil, "saved player starts closed")
        check(host.frames[wide ? .detailsButton : .firstMeetingAction] == nil, "details switch between column and button at this width")

        host.click(collapsed[3].center)
        if let expanded = frames([.transcriptSearch, action, .meetingContent, .waveform], in: host) {
            equal(expanded[0].minY, expanded[1].minY, "opening the player moves search and actions together")
            equal(expanded[3].minX, expanded[2].minX, "inline waveform starts at the content's left edge")
            equal(expanded[3].maxX, expanded[2].maxX, "inline waveform reaches the right edge, including above the actions column")
            check(expanded[0].minY > collapsed[0].minY, "player pushes the transcript down instead of covering it")
        }
        host.click(collapsed[3].center)
        check(host.wait { host.frames[.waveform] == nil }, "second press closes the player")
        if let restored = host.frames[.transcriptSearch] {
            equal(restored.minY, collapsed[0].minY, "closing the player restores the transcript layout")
        }
    }

    private func checkSetup(_ setup: ModelSetup, scale: CGFloat) {
        defer { setup.phase = .ready }
        for phase in [ModelSetup.Phase.available, .ready] {
            scenario = "model setup \(phase), \(Int(scale * 100))%"
            setup.phase = phase
            let host = LayoutHost(ModelSetupView(setup: setup, onReady: {}), size: CGSize(width: 600, height: 660), scale: scale)
            defer { host.close() }
            if let measured = frames([.setupStatus, .setupAction], in: host) {
                equal(measured[1].minY - measured[0].maxY, 24, "setup status has one section gap before the primary button")
                check(measured[1].maxY <= host.bounds.maxY, "primary action remains inside the window")
            }
        }
    }

    private func checkRecordingLevels(_ monitor: RecordingMonitor, scale: CGFloat) {
        scenario = "recording levels, \(Int(scale * 100))%"
        monitor.reset()
        let now = monitor.now + 5
        monitor.now = now
        monitor.microphone.update(peak: 0.05, seconds: 5, lastWrite: now, now: now)
        let host = LayoutHost(RecordingWaveformView(monitor: monitor), size: CGSize(width: 500, height: 220), scale: scale)
        defer { host.close() }
        if let measured = frames([.microphoneLabel, .systemAudioLabel, .systemAudioWarning], in: host) {
            equal(measured[0].minX, measured[1].minX, "microphone and system audio labels share a left edge")
            equal(measured[1].minX, measured[2].minX, "signal warning is aligned below its source label")
            check(host.frames[.microphoneWarning] == nil, "a warning is shown only for the missing signal")
        }
    }

    private func checkForms(state: AppState, meeting: Meeting, scale: CGFloat) {
        scenario = "dictionary form, \(Int(scale * 100))%"
        do {
            let host = LayoutHost(SettingsView(initialSection: "Голоса").environmentObject(state),
                                  size: CGSize(width: 900, height: 700), scale: scale)
            defer { host.close() }
            let tabs = ["Запись", "Модель", "Голоса", "Словарь", "Экспорт", "Хранилище", "MCP", "Обновления"]
            if let tabFrames = frames(tabs.map(InterfaceLayoutElement.settingsTab), in: host) {
                check(zip(tabFrames, tabFrames.dropFirst()).allSatisfy { left, right in left.maxX <= right.minX },
                      "settings tabs appear in order without overlapping")
                check(tabFrames.allSatisfy { host.bounds.contains($0) }, "all settings tabs fit in the window")
                host.click(tabFrames[3].center)
            }
            if let measured = frames([.dictionarySearch, .dictionaryEntry, .dictionaryAdd, .dictionaryResult], in: host) {
                checkFormRow(measured.prefix(3))
                checkField(.dictionarySearch, placeholder: true, value: "ПППППП", in: host)
                checkField(.dictionaryEntry, placeholder: true, value: "ПППППП", in: host)
                if let field = host.field(in: measured[0]) {
                    check(host.type("", into: field), "dictionary search query can be cleared")
                    host.blur()
                }
                let result = measured[3]
                check(!host.hasYellowHighlight(in: result), "an empty query does not highlight the dictionary entry")
                if let search = host.field(in: measured[0]) {
                    equal(search.font?.pointSize ?? 0, 16 * scale, "dictionary search uses the body font")
                    let typed = host.type("иса", into: search)
                    check(typed, "dictionary search accepts native text input")
                    let highlighted = host.wait { host.hasYellowHighlight(in: result) }
                    check(highlighted, "matching dictionary text is rendered with a yellow highlight")
                } else { check(false, "dictionary search exposes a native text field") }
                if let entry = host.field(in: measured[1]) {
                    equal(entry.font?.pointSize ?? 0, 16 * scale, "dictionary entry uses the same body font")
                } else { check(false, "dictionary entry exposes a native text field") }
            }
        }

        scenario = "term review form, \(Int(scale * 100))%"
        let host = LayoutHost(TermReview(meeting: meeting).environmentObject(state), size: CGSize(width: 940, height: 660), scale: scale)
        defer { host.close() }
        if let measured = frames([.termSearch, .termFind], in: host) {
            checkFormRow(measured[...])
            checkField(.termSearch, placeholder: true, value: "Писая", nativePlaceholder: "Слово или фраза", in: host)
            if let search = host.field(in: measured[0], placeholder: "Слово или фраза") {
                check(host.focus(search), "term search is focused before submitting the query")
                host.pressReturn()
                checkField(.termReplacement, placeholder: false, nativePlaceholder: "Термин", in: host)
                checkField(.termReplacement, placeholder: true, clear: true, nativePlaceholder: "Термин", in: host)
            }
        }
    }

    private func checkScreenFields(state: AppState, meeting: Meeting, voiceMeeting: Meeting,
                                   savedVoice: VoiceProfile, scale: CGFloat) {
        let percent = Int((scale * 100).rounded())
        for size in [CGSize(width: 980, height: 660), CGSize(width: 1200, height: 800)] {
            scenario = "main window focus, \(Int(size.width))×\(Int(size.height)), \(percent)%"
            state.select(meeting.id)
            state.search = ""
            let host = LayoutHost(MainView().environmentObject(state), size: size, scale: scale)
            defer {
                host.close()
                state.search = ""
            }
            checkField(.meetingTitle, placeholder: false, in: host)
            checkField(.transcriptSearch, placeholder: true, value: "ПППППП", in: host)
            checkField(.librarySearch, placeholder: true, value: "ПППППП", in: host)
        }

        scenario = "dictionary edit, \(percent)%"
        if let entry = VocabularyDictionary.entries(in: state.preferences.vocabulary).first {
            let host = LayoutHost(VocabularyEditForm(entry: entry).environmentObject(state),
                                  size: CGSize(width: 500, height: 260), scale: scale)
            defer { host.close() }
            checkField(.dictionaryEdit, placeholder: false, in: host)
            checkField(.dictionaryEdit, placeholder: true, clear: true, in: host)
        } else {
            check(false, "dictionary edit fixture has an entry")
        }

        scenario = "rename recording, \(percent)%"
        do {
            let host = LayoutHost(NameEditor(title: "Переименовать запись", initial: "ПППППП") { _ in },
                                  size: CGSize(width: 450, height: 240), scale: scale)
            defer { host.close() }
            checkInitialFocus(.renameField, in: host)
            checkField(.renameField, placeholder: false, in: host)
        }

        scenario = "new folder, \(percent)%"
        do {
            let host = LayoutHost(FolderEditor(folder: nil) { _, _ in },
                                  size: CGSize(width: 420, height: 500), scale: scale)
            defer { host.close() }
            checkInitialFocus(.folderName, in: host)
            checkField(.folderName, placeholder: true, value: "ПППППП", in: host)
        }

        scenario = "voice labeling, \(percent)%"
        do {
            let host = LayoutHost(VoiceManager(meetingID: voiceMeeting.id).environmentObject(state),
                                  size: CGSize(width: 940, height: 660), scale: scale)
            defer { host.close() }
            if let segment = voiceMeeting.segments.first, let sample = frames([.voiceSample(segment.id)], in: host)?.first {
                host.click(sample.center)
                checkField(.voiceName, placeholder: false, nativePlaceholder: "Имя участника", in: host)
                checkField(.voiceName, placeholder: true, clear: true, nativePlaceholder: "Имя участника", in: host)
                if let frame = host.frames[.voiceName], let name = host.field(in: frame, placeholder: "Имя участника") {
                    check(host.type(String(savedVoice.name.prefix(3)), into: name), "voice name accepts a suggestion prefix")
                    host.pressKey("\u{f701}", keyCode: 125)
                    host.pressReturn()
                    check(host.wait { name.currentEditor()?.string == savedVoice.name }, "Down then Return fills the highlighted saved name")
                    check(host.isEditing(name), "selecting a suggestion keeps the name field focused")
                    check(state.meetings.first(where: { $0.id == voiceMeeting.id })?.segments.first?.speaker == segment.speaker,
                          "choosing a suggestion leaves the transcript speaker unchanged until applying the name")
                } else {
                    check(false, "voice name is available for keyboard suggestion selection")
                }
            }
        }

        scenario = "saved voice search, \(percent)%"
        do {
            let host = LayoutHost(SettingsView(initialSection: "Голоса").environmentObject(state),
                                  size: CGSize(width: 900, height: 700), scale: scale)
            defer { host.close() }
            checkField(.savedVoiceSearch, placeholder: true, value: "ПППППП", in: host)
        }

        scenario = "voice merge search, \(percent)%"
        checkVoiceMerge(state: state, savedVoice: savedVoice, scale: scale)

        scenario = "saved voice rename, \(percent)%"
        let host = LayoutHost(SavedVoiceNameEditor(profile: savedVoice) { _ in }.environmentObject(state),
                              size: CGSize(width: 540, height: 300), scale: scale)
        defer { host.close() }
        checkInitialFocus(.savedVoiceName, in: host)
        checkField(.savedVoiceName, placeholder: false, in: host)
        checkField(.savedVoiceName, placeholder: true, clear: true, in: host)
    }

    private func checkVoiceMerge(state: AppState, savedVoice: VoiceProfile, scale: CGFloat) {
        let first = VoiceProfile(name: "Борис", samples: [])
        let other = (1...8).map { VoiceProfile(name: "Участник \($0)", samples: []) }
        let previousProfiles = state.voiceProfiles
        state.voiceProfiles = [savedVoice, first] + other
        let host = LayoutHost(SavedVoiceMergeEditor(profile: savedVoice) { _ in }.environmentObject(state),
                              size: CGSize(width: 540, height: 420), scale: scale)
        defer {
            host.close()
            state.voiceProfiles = previousProfiles
        }

        func checkCandidateInsets(_ context: String) {
            guard let measured = frames([.voiceMergeList, .voiceMergeCandidate(first.id)], in: host) else { return }
            let list = measured[0], row = measured[1]
            equal(row.minX - list.minX, PisaDesign.Spacing.compact, "\(context): candidate left inset")
            equal(list.maxX - row.maxX, PisaDesign.Spacing.compact, "\(context): candidate right inset")
        }

        checkCandidateInsets("full list")
        checkField(.voiceMergeSearch, placeholder: true, value: first.name, in: host)
        check(host.wait { host.frames[.voiceMergeCandidate(other[0].id)] == nil }, "search filters out other voices")
        checkCandidateInsets("filtered list")
        checkField(.voiceMergeSearch, placeholder: true, clear: true, in: host)
        check(host.wait { host.frames[.voiceMergeCandidate(other[0].id)] != nil }, "clearing search restores other voices")
        checkCandidateInsets("restored list")
    }

    private func checkInitialFocus(_ element: InterfaceLayoutElement, in host: LayoutHost) {
        guard let frame = frames([element], in: host)?.first, let field = host.field(in: frame) else {
            check(false, "\(element): rename or creation dialog exposes its input field")
            return
        }
        check(host.wait { host.isEditing(field) }, "\(element): opening the dialog focuses the field")
    }

    private func checkField(_ element: InterfaceLayoutElement, placeholder: Bool, value: String? = nil,
                            clear: Bool = false, nativePlaceholder: String? = nil, in host: LayoutHost) {
        guard let frame = frames([element], in: host)?.first,
              let field = host.field(in: frame, placeholder: nativePlaceholder) else {
            check(false, "\(element): the production screen exposes an editable field")
            return
        }
        if clear { check(host.type("", into: field), "\(element): native editing clears the field") }
        checkFieldOrigin(element, placeholder: placeholder, field: field, host: host)
        if let value {
            check(host.type(value, into: field), "\(element): native editing sets the fixture text")
            checkFieldOrigin(element, placeholder: false, field: field, host: host)
        }
    }

    private func checkFieldOrigin(_ element: InterfaceLayoutElement, placeholder: Bool, field: NSTextField, host: LayoutHost) {
        let label = "\(element) \(placeholder ? "placeholder" : "value")"
        host.blur()
        let hasExpectedText = placeholder == field.stringValue.isEmpty
        check(hasExpectedText, "\(label): field is in the expected state")
        guard hasExpectedText else { return }
        guard let region = host.glyphRegion(for: field), let blurred = host.textInk(in: region) else {
            check(false, "\(label): text is rendered before focus")
            return
        }
        check(host.focus(field), "\(label): native field editor receives focus")
        guard let focused = host.textInk(in: region) else {
            check(false, "\(label): text remains visible when focused")
            return
        }
        let difference = CGPoint(x: focused.origin.x - blurred.origin.x, y: focused.origin.y - blurred.origin.y)
        check(abs(difference.x) <= blurred.tolerance && abs(difference.y) <= blurred.tolerance,
              "\(label): focusing keeps the text in place (delta x=\(difference.x), y=\(difference.y) pt)")
        host.blur()
        guard let restored = host.textInk(in: region) else {
            check(false, "\(label): text remains visible after blur")
            return
        }
        check(abs(restored.origin.x - blurred.origin.x) <= blurred.tolerance &&
              abs(restored.origin.y - blurred.origin.y) <= blurred.tolerance,
              "\(label): blurring restores the original text position")
    }

    private func checkFormRow(_ row: ArraySlice<CGRect>) {
        guard let first = row.first else { return }
        for frame in row {
            equal(frame.height, 36, "ordinary form control has the standard height")
            equal(frame.midY, first.midY, "fields and actions are vertically aligned within the form")
        }
    }
}

@MainActor
private final class LayoutHost {
    private let window: NSWindow
    private let view: NSHostingView<AnyView>
    private(set) var frames: [InterfaceLayoutElement: CGRect] = [:]
    var bounds: CGRect { view.bounds }

    init<Content: View>(_ content: Content, size: CGSize, scale: CGFloat) {
        let bounds = CGRect(origin: .zero, size: size)
        view = NSHostingView(rootView: AnyView(EmptyView()))
        window = NSWindow(contentRect: bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Pisa · Тест интерфейса"
        view.sizingOptions = []
        view.rootView = AnyView(
            content
                .frame(width: size.width, height: size.height)
                .coordinateSpace(name: "interface-layout-test")
                .environment(\.measuresInterfaceLayout, true)
                .environment(\.appTextScale, scale)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .preferredColorScheme(.light)
                .background(Color.paper)
                .onPreferenceChange(InterfaceFrames.self) { [weak self] in self?.frames = $0 }
        )
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        settle()
    }

    func close() { window.close(); settle() }

    func settle() {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.025))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    func wait(seconds: TimeInterval = 2, for condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            settle()
            if condition() { return true }
        } while Date() < end
        return false
    }

    func click(_ point: CGPoint) {
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        let location = view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                               pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(event)
            }
        }
        settle()
    }

    func field(in frame: CGRect, placeholder: String? = nil) -> NSTextField? {
        func find(_ node: NSView) -> NSTextField? {
            if let field = node as? NSTextField, field.isEditable {
                // HSplitView hosts its panes in distinct SwiftUI coordinate
                // spaces. Match their unique field labels in the native tree.
                if let placeholder {
                    let actual = field.placeholderString ?? field.placeholderAttributedString?.string
                    if actual == placeholder || actual == typographicText(placeholder) { return field }
                } else {
                    let rect = field.convert(field.bounds, to: view)
                    let point = CGPoint(x: rect.midX, y: view.isFlipped ? rect.midY : view.bounds.height - rect.midY)
                    if frame.contains(point) { return field }
                }
            }
            return node.subviews.lazy.compactMap { find($0) }.first
        }
        return find(view)
    }

    func pressReturn() { pressKey("\r", keyCode: 36) }

    func pressKey(_ character: String, keyCode: UInt16) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: character,
                                            charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode) {
                window.sendEvent(event)
            }
        }
        settle()
    }

    func isEditing(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return window.firstResponder === editor
    }

    func focus(_ field: NSTextField) -> Bool {
        guard window.makeFirstResponder(field) else { return false }
        field.selectText(nil)
        settle()
        guard let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else { return false }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        settle()
        return true
    }

    func blur() {
        window.makeFirstResponder(nil)
        settle()
    }

    func type(_ text: String, into field: NSTextField) -> Bool {
        guard focus(field), let editor = field.currentEditor() else { return false }
        editor.selectAll(nil)
        editor.insertText(text)
        settle()
        return field.stringValue == text || editor.string == text
    }

    func glyphRegion(for field: NSTextField) -> CGRect? {
        guard let font = field.font else { return nil }
        let rect = field.convert(field.bounds, to: view)
        let y = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
        let sample = field.stringValue.isEmpty ?
            (field.placeholderString ?? field.placeholderAttributedString?.string ?? "") : field.stringValue
        let textWidth = (sample as NSString).size(withAttributes: [.font: font]).width
        // The fixed crop omits the caret and the surrounding control chrome.
        let width = min(textWidth, rect.width, 180) - 8
        guard width > 0 else { return nil }
        return CGRect(x: rect.minX + 4, y: y - 3, width: width, height: rect.height + 6)
    }

    func textInk(in region: CGRect) -> (origin: CGPoint, tolerance: CGFloat)? {
        guard let image = renderedHost() else { return nil }
        let sx = CGFloat(image.pixelsWide) / view.bounds.width
        let sy = CGFloat(image.pixelsHigh) / view.bounds.height
        let left = max(0, Int(floor(region.minX * sx)))
        let right = min(image.pixelsWide, Int(ceil(region.maxX * sx)))
        let top = max(0, Int(floor(region.minY * sy)))
        let bottom = min(image.pixelsHigh, Int(ceil(region.maxY * sy)))
        guard left < right, top < bottom else { return nil }
        var minX = right, minY = bottom
        for y in top..<bottom {
            for x in left..<right {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.8,
                      max(color.redComponent, color.greenComponent, color.blueComponent) < 0.74 else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
            }
        }
        guard minX < right, minY < bottom else { return nil }
        return (CGPoint(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy), min(0.5, 1 / max(sx, sy)))
    }

    // Read only pixels from the synthetic host, in memory. No desktop capture.
    private func renderedHost() -> NSBitmapImageRep? {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    func hasYellowHighlight(in frame: CGRect) -> Bool {
        guard let image = renderedHost() else { return false }
        let scale = CGFloat(image.pixelsWide) / view.bounds.width
        let x = Int(frame.minX * scale)..<min(image.pixelsWide, Int(frame.maxX * scale))
        let y = Int(frame.minY * scale)..<min(image.pixelsHigh, Int(frame.maxY * scale))
        var yellowPixels = 0
        for row in y {
            for column in x {
                guard let color = image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent > 0.90, color.greenComponent > 0.78, color.greenComponent < 0.97,
                   color.blueComponent < 0.65 {
                    yellowPixels += 1
                    if yellowPixels >= 12 { return true }
                }
            }
        }
        return false
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
