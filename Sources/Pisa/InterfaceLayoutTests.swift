import AppKit
import AVFoundation
import SwiftUI

// Attach passive measurements only when a test host supplies the named space.
enum InterfaceLayoutElement: Hashable {
    case welcomeContent, welcomeTitle, welcomeDescription, welcomeAction
    case mainToolbar, meetingMetadata, meetingTitle, meetingContent, meetingStatus, audioToggle, waveform
    case transcriptionStatusHeading, transcriptionStatusAction, transcriptionProgressCaption, transcriptionProgressRow
    case audioToggleLabel
    case transcriptSearch, librarySearch, firstMeetingAction, detailsButton
    case sidebarRecording(UUID), sidebarTranscriptionStatus(UUID, String)
    case setupStatus, setupAction
    case microphoneLabel, systemAudioLabel, microphoneWarning, systemAudioWarning
    case settingsTab(String), settingsTabBar, settingsContent(String)
    case settingsModelHeading, settingsModelAction, settingsModelDownloadSize
    case settingsModelFolder, settingsModelPath, settingsModelChooseFolder
    case settingsStorageUsage, settingsStorageCleanup, settingsStorageAge, settingsStorageAction
    case exportToggle, exportPath, exportChooseFolder, exportUnavailableNotice, exportCloudNotice
    case mcpAccessToggle, mcpAccessNotice, mcpCopyConfiguration
    case dictionaryHeading, dictionarySearch, dictionaryEntry, dictionaryAdd, dictionaryResult, dictionaryEdit, dictionaryRow(Int)
    case termSearch, termFind, termReplacement
    case termCandidate(String)
    case renameField, folderName, voiceName, voiceSample(UUID), savedVoiceSearch, savedVoiceName, voiceMergeSearch
    case savedVoiceHeading, savedVoiceRow(UUID)
    case voiceMergeList, voiceMergeCandidate(UUID)
    case voiceAllMatching, voiceSuggestion(String)
}

private struct InterfaceFrames: PreferenceKey {
    static var defaultValue: [InterfaceLayoutElement: CGRect] { [:] }
    static func reduce(value: inout [InterfaceLayoutElement: CGRect], nextValue: () -> [InterfaceLayoutElement: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

extension EnvironmentValues {
    @Entry fileprivate var measuresInterfaceLayout = false
    // Only the website renderer supplies this; ordinary meetings keep their normal order.
    @Entry var websiteScreenshotParticipantOrder: [String]? = nil
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
    private struct WebsiteFixture: Decodable {
        struct Line: Decodable {
            let speaker: String
            let text: String
            let start: TimeInterval
            let end: TimeInterval
        }
        struct Recording: Decodable {
            let title: String
            let date: String
            let duration: TimeInterval
        }
        let title: String
        let date: String
        let duration: TimeInterval
        let otherMeetings: [Recording]
        let dialogue: [Line]
    }

    // Render production views from a disposable library, without reading screen pixels.
    static func renderWebsiteScreenshots(fixtureURL: URL, output: URL) throws {
        guard NSScreen.main != nil else { throw PisaError.message("Снимкам нужен сеанс WindowServer") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let fixture = try JSONDecoder().decode(WebsiteFixture.self, from: Data(contentsOf: fixtureURL))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Website-Render-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = AppState(rootURL: root)
        state.modelSetup.phase = .ready
        state.preferences.summaryOnboardingAcknowledged = true
        let dateParser = ISO8601DateFormatter()
        func recording(title: String, date: String, duration: TimeInterval) throws -> Meeting {
            guard let date = dateParser.date(from: date), duration > 0 else {
                throw PisaError.message("Некорректная дата или длительность демонстрационной встречи")
            }
            var meeting = Meeting(title: title, source: "Zoom")
            meeting.status = .ready
            meeting.date = date
            meeting.duration = duration
            return meeting
        }
        let participantOrder = fixture.dialogue.reduce(into: [String]()) { names, line in
            if !names.contains(line.speaker) { names.append(line.speaker) }
        }
        let host = LayoutHost(MainView().environmentObject(state)
            .environment(\.websiteScreenshotParticipantOrder, participantOrder)
            .environment(\.showsControlKeyboardFocus, false),
            size: CGSize(width: 1480, height: 900), scale: 1)
        defer { host.close() }
        guard host.wait(for: { host.frames[.welcomeTitle]?.isEmpty == false }) else {
            throw PisaError.message("Главный экран не отобразился")
        }
        try host.savePNG(to: output.appendingPathComponent("welcome.png"))

        var meeting = try recording(title: fixture.title, date: fixture.date, duration: fixture.duration)
        meeting.segments = try fixture.dialogue.map { line in
            guard line.start >= 0, line.end > line.start, line.end <= meeting.duration else {
                throw PisaError.message("Некорректное время демонстрационной реплики")
            }
            return TranscriptSegment(start: line.start, end: line.end, speaker: line.speaker, text: line.text)
        }
        for other in fixture.otherMeetings.reversed() {
            state.update(try recording(title: other.title, date: other.date, duration: other.duration))
        }
        state.update(meeting)
        state.select(meeting.id)
        guard host.wait(for: { host.frames[.transcriptSearch]?.isEmpty == false && host.frames[.meetingTitle]?.isEmpty == false }) else {
            throw PisaError.message("Расшифровка не отобразилась")
        }
        try host.savePNG(to: output.appendingPathComponent("transcript.png"))
    }

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
            // Run this scenario in AppKit's event loop so the candidate and
            // occurrence tasks can resume between interactions.
            if !runTermReplacement(state: AppState(rootURL: root.appendingPathComponent("term-review")), app: app) {
                return 1
            }
            try suite.checkScreens(state: state)
            var result: Int32 = 1
            // Keep the focus probes outside a MainActor task. The model actions
            // suspend separately so the run loop can deliver their results.
            Task { @MainActor in
                defer { CFRunLoopStop(CFRunLoopGetMain()) }
                do {
                    for scale: CGFloat in [1, 1.2] {
                        try await suite.checkModelSettings(state: state, scale: scale)
                    }
                    print("INTERFACE_LAYOUT_TEST_RESULT checks=\(suite.checks) failures=\(suite.failures)")
                    result = suite.failures == 0 && suite.checks > 0 ? 0 : 1
                } catch {
                    fputs("MODEL_SETTINGS_LAYOUT_TEST_FAILED: \(error)\n", stderr)
                }
            }
            CFRunLoopRun()
            return result
        } catch {
            fputs("INTERFACE_LAYOUT_TEST_FAILED: \(error)\n", stderr)
            return 1
        }
    }

    private static func runTermReplacement(state: AppState, app: NSApplication) -> Bool {
        var passed = false
        Task { @MainActor in
            do {
                try await checkTermReplacement(state: state)
                passed = true
            } catch {
                fputs("TERM_REVIEW_INTERFACE_FAILED: \(error)\n", stderr)
            }
            app.stop(nil)
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                app.postEvent(event, atStart: true)
            }
        }
        app.run()
        return passed
    }

    private static func checkTermReplacement(state: AppState) async throws {
        var meeting = Meeting(title: "Разметка терминов", source: "Тест интерфейса")
        meeting.status = .ready
        meeting.segments = (0..<1_800).map { index in
            TranscriptSegment(start: Double(index), end: Double(index + 1), speaker: "Анна",
                              text: "Обсудили MapKit, LLM и Qwen3-ASR.")
        }
        state.update(meeting)
        let candidates = TermReview.CandidateList()
        let size = CGSize(width: 940, height: 660)
        func wait(in host: LayoutHost, for condition: () -> Bool) async throws -> Bool {
            let deadline = ContinuousClock.now + .seconds(20)
            repeat {
                host.settle()
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
            return false
        }
        do {
            let host = LayoutHost(TermReview(meeting: meeting, candidateList: candidates).environmentObject(state),
                                  size: size, scale: 1)
            defer { host.close() }
            guard try await wait(in: host, for: { candidates.snapshot?.candidates.contains { $0.text == "MapKit" } == true }) else {
                throw PisaError.message("The candidate scan did not find MapKit")
            }
            guard host.frames[.termCandidate("MapKit")] != nil,
                  let search = host.field(in: .zero, placeholder: "Слово или фраза"),
                  host.type("MapKit", into: search) else {
                throw PisaError.message("Initial term candidates and search did not render")
            }
            host.pressReturn()
            guard let replacement = host.field(in: .zero, placeholder: "Термин"),
                  host.type("платформа", into: replacement) else {
                throw PisaError.message("Replacement field did not accept a term")
            }
            guard try await wait(in: host, for: {
                host.pressReturn(settle: false)
                return state.canUndoTermReplacement(meetingID: meeting.id)
            }) else {
                throw PisaError.message("Term review did not save the correction")
            }
            guard let visible = candidates.snapshot?.candidates,
                  !visible.contains(where: { $0.text == "MapKit" }),
                  visible.contains(where: { $0.text == "LLM" }),
                  try await wait(in: host, for: { host.frames[.termCandidate("MapKit")] == nil &&
                      host.frames[.termCandidate("LLM")] != nil && host.frames[.termCandidate("Qwen3-ASR")] != nil }) else {
                throw PisaError.message("The corrected term stayed in the candidate list after saving")
            }
        }

        // Reopen after a saved edit made outside the dialog invalidates its prewarmed list.
        guard let current = state.meetings.first(where: { $0.id == meeting.id }) else {
            throw PisaError.message("The corrected meeting is missing")
        }
        let qwen = TranscriptTerms.matches("Qwen3-ASR", in: current.segments)
        guard !qwen.isEmpty else { throw PisaError.message("The second candidate has no test occurrences") }
        try state.replaceTerms(qwen, with: "модель", meetingID: meeting.id)
        let reopened = LayoutHost(TermReview(meeting: current, candidateList: candidates).environmentObject(state),
                                  size: size, scale: 1.2)
        defer { reopened.close() }
        guard reopened.frames[.termCandidate("Qwen3-ASR")] == nil,
              try await wait(in: reopened, for: { reopened.frames[.termCandidate("LLM")] != nil }),
              reopened.frames[.termCandidate("Qwen3-ASR")] == nil else {
            throw PisaError.message("Reopening the term review showed a stale candidate")
        }
        print("TERM_REVIEW_INTERFACE_OK immediate_candidate_removal fresh_reopen")
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

    private func saveScreenshot(_ name: String, in host: LayoutHost) throws {
        guard let path = ProcessInfo.processInfo.environment["PISA_LAYOUT_SCREENSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try host.savePNG(to: directory.appendingPathComponent(name + ".png"))
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
        queued.title = "Планирование"
        var processing = saved
        processing.id = UUID()
        processing.title = "Обсуждение результатов прошлогодней встречи с командой"
        processing.date = Calendar.current.date(byAdding: .year, value: -2, to: .now) ?? .now
        processing.duration = 3_670
        processing.folderID = state.saveFolder("Документы и рабочие созвоны")
        processing.status = .processing
        var interrupted = ready
        interrupted.id = UUID()
        interrupted.title = "Разбор прототипа"
        interrupted.status = .failed
        interrupted.liveCommittedUntil = 0.4
        interrupted.error = "Обработка остановлена. Аудио сохранено."
        for meeting in [ready, saved, queued, processing, interrupted] { state.update(meeting) }
        state.processingID = processing.id
        state.phase = "Доля обработанного аудио"
        state.progress = 0.99
        state.preferences.quietProcessing = false
        state.enqueue(queued.id)
        state.preferences.vocabulary = "Писая\nЯндекс"

        for (size, scale) in [(CGSize(width: 980, height: 660), 1.0), (CGSize(width: 1200, height: 800), 1.2),
                              (CGSize(width: 1200, height: 800), 1.0), (CGSize(width: 980, height: 660), 1.2)] {
            scenario = "main \(Int(size.width))×\(Int(size.height)), \(Int(scale * 100))%"
            state.select(nil)
            let host = LayoutHost(MainView().environmentObject(state), size: size, scale: scale)
            defer { host.close() }
            checkWelcome(in: host)
            checkSidebarStatuses(in: host, state: state, queued: queued.id, processing: processing.id,
                                 interrupted: interrupted)
            state.select(ready.id)
            guard let reference = checkMeetingHeader(in: host) else { continue }
            checkTranscript(in: host, wide: size.width > 980)
            try saveScreenshot("meeting-\(Int(size.width))-\(Int(scale * 100))", in: host)

            var processingPositions: (heading: CGRect, action: CGRect, progress: CGRect)?
            for (meeting, firstContent) in [(saved, InterfaceLayoutElement.waveform), (queued, .meetingStatus),
                                            (processing, .meetingStatus), (interrupted, .meetingStatus)] {
                scenario = "\(meeting.title) \(Int(size.width))×\(Int(size.height)), \(Int(scale * 100))%"
                state.select(meeting.id)
                host.settle()
                if let title = checkMeetingHeader(in: host, titleGap: firstContent == .meetingStatus ? 8 : 16) {
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
                if meeting.id == processing.id {
                    processingPositions = checkTranscriptionProgress(in: host)
                    // Preparing a resumed recording has no known duration yet.
                    // Its caption and bar must not disappear and shift the transcript.
                    state.liveStatus = "Подготавливаю аудио"
                    host.settle()
                    if let preparing = checkTranscriptionProgress(in: host), let processingPositions {
                        equal(preparing.progress.minY, processingPositions.progress.minY, "preparing keeps the progress bar in place")
                    }
                    state.liveStatus = ""
                } else if meeting.id == interrupted.id,
                          let interruptedPositions = checkTranscriptionProgress(in: host),
                          let processingPositions {
                    equal(interruptedPositions.heading.minY, processingPositions.heading.minY, "status heading starts at the same height")
                    equal(interruptedPositions.action.minY, processingPositions.action.minY, "action starts at the same height")
                    equal(interruptedPositions.progress.minY, processingPositions.progress.minY, "progress stays at the same height when transcription stops")
                }
            }
            if let output = ProcessInfo.processInfo.environment["PISA_SIDEBAR_TEST_SCREENSHOTS"] {
                let name = "sidebar-\(Int(size.width))x\(Int(size.height))-\(Int(scale * 100)).png"
                try host.savePNG(to: URL(fileURLWithPath: output, isDirectory: true).appendingPathComponent(name))
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
            try checkIntegrationSettings(state: state, scale: scale)
            try checkScreenFields(state: state, meeting: ready, voiceMeeting: voiceMeeting, savedVoice: savedVoice, scale: scale)
        }
    }

    private func checkSidebarStatuses(in host: LayoutHost, state: AppState, queued: UUID,
                                      processing: UUID, interrupted: Meeting) {
        func checkStatus(_ id: UUID, _ label: String) {
            let element = InterfaceLayoutElement.sidebarTranscriptionStatus(id, label)
            guard let measured = frames([.sidebarRecording(id), element], in: host) else { return }
            check(measured[0].insetBy(dx: -0.5, dy: -0.5).contains(measured[1]), "full status fits inside the recording row")
        }
        checkStatus(queued, "В очереди")
        checkStatus(processing, "Расшифровка · 99%")
        checkStatus(interrupted.id, "Остановлена")

        state.phase = ""
        checkStatus(processing, "Расшифровка")
        state.phase = "Доля обработанного аудио"
        state.progress = 0.9
        checkStatus(processing, "Расшифровка · 90%")
        state.progress = 0.99

        state.enqueue(interrupted.id)
        checkStatus(interrupted.id, "В очереди")
        state.cancelQueued(interrupted.id)
        checkStatus(interrupted.id, "Остановлена")

        var earlyStop = interrupted
        earlyStop.segments = []
        earlyStop.liveCommittedUntil = nil
        earlyStop.error = "Не удалось прочитать аудио"
        state.update(earlyStop)
        let stoppedLabel = InterfaceLayoutElement.sidebarTranscriptionStatus(interrupted.id, "Остановлена")
        check(host.wait { host.frames[.sidebarRecording(interrupted.id)] != nil && host.frames[stoppedLabel] == nil },
              "a transcription error does not display the stopped status")
        earlyStop.error = "Обработка прервалась. Аудио сохранено — можно повторить"
        state.update(earlyStop)
        checkStatus(interrupted.id, "Остановлена")
        state.update(interrupted)
    }

    private func checkIntegrationSettings(state: AppState, scale: CGFloat) throws {
        let size = CGSize(width: 900, height: 700)
        let exportFolder = state.library.root.appendingPathComponent("Расшифровки тестовых встреч", isDirectory: true)
        try FileManager.default.createDirectory(at: exportFolder, withIntermediateDirectories: true)
        let host = LayoutHost(SettingsView(initialSection: "Экспорт").environmentObject(state), size: size, scale: scale)
        defer { host.close() }

        func checkExport(_ name: String, hasFolder: Bool, unavailable: Bool = false) throws {
            scenario = "export \(name), \(Int(scale * 100))%"
            guard let toggle = frames([.exportToggle], in: host)?.first else { return }
            check(host.bounds.contains(toggle), "export checkbox fits in the window")
            if hasFolder {
                guard let measured = frames([.exportPath, .exportChooseFolder, .exportCloudNotice], in: host) else { return }
                let (path, choose, notice) = (measured[0], measured[1], measured[2])
                check(measured.allSatisfy { host.bounds.contains($0) }, "folder controls and cloud notice fit in the window")
                equal(toggle.minX, path.minX, "checkbox and path share a left edge")
                check(toggle.maxY <= path.minY && path.maxY <= choose.minY, "saved path is shown between the checkbox and folder action")
                equal(choose.minX, notice.minX, "cloud sync notice is aligned below the folder action")
                equal(notice.minY - choose.maxY, PisaDesign.Spacing.inline, "cloud sync notice is directly below the folder action")
            } else {
                check(host.frames[.exportPath] == nil && host.frames[.exportChooseFolder] == nil && host.frames[.exportCloudNotice] == nil,
                      "folder controls are hidden when auto-export is off")
            }
            check((host.frames[.exportUnavailableNotice] != nil) == unavailable, "an unavailable folder has a recovery notice")
            try saveScreenshot("export-\(name)-\(Int(scale * 100))", in: host)
        }

        try checkExport("off", hasFolder: false)
        if scale == 1, let toggle = frames([.exportToggle], in: host)?.first {
            let cancelPicker = Timer(timeInterval: 0.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let picker = NSApp.modalWindow as? NSOpenPanel
                    self.check(picker != nil, "checking auto-export opens the folder picker")
                    if let picker {
                        picker.cancel(nil)
                    } else {
                        NSApp.stopModal(withCode: .cancel)
                    }
                }
            }
            RunLoop.main.add(cancelPicker, forMode: .modalPanel)
            host.click(toggle.center)
            check(!cancelPicker.isValid, "the folder picker entered its modal loop")
            cancelPicker.invalidate()
            check(state.preferences.exportBookmark == nil && host.frames[.exportPath] == nil,
                  "canceling the folder picker leaves auto-export off")
        }
        state.preferences.exportDisplayPath = exportFolder.path
        state.preferences.exportBookmark = Data("unavailable fixture bookmark".utf8)
        state.refreshExportFolderAccess()
        try checkExport("paused", hasFolder: true, unavailable: true)

        try state.setExportFolder(exportFolder)
        try checkExport("on", hasFolder: true)
        if let toggle = frames([.exportToggle], in: host)?.first {
            host.click(toggle.center)
            let saved = try state.library.preferences()
            check(saved.exportBookmark == nil && saved.exportDisplayPath == nil, "unchecking auto-export clears the saved folder")
            try checkExport("off", hasFolder: false)
        }
        try state.setExportFolder(nil)

        scenario = "MCP access, \(Int(scale * 100))%"
        state.preferences.mcpEnabled = false
        guard let tab = frames([.settingsTab("MCP")], in: host)?.first else { return }
        host.click(tab.center)
        guard let measured = frames([.mcpAccessToggle, .mcpAccessNotice, .mcpCopyConfiguration], in: host) else { return }
        let (toggle, notice, copy) = (measured[0], measured[1], measured[2])
        check(measured.allSatisfy { host.bounds.contains($0) }, "MCP access checkbox, notice and configuration action fit in the window")
        equal(notice.minY - toggle.maxY, 20, "MCP data access notice has a 20-point gap below the checkbox")
        equal(notice.minX, toggle.minX, "MCP data access notice and checkbox share a left edge")
        try saveScreenshot("mcp-off-\(Int(scale * 100))", in: host)
        host.click(toggle.center)
        let enabled = try state.library.preferences().mcpEnabled
        check(enabled, "MCP checkbox enables access in the saved library settings")
        check(host.frames[.mcpAccessNotice] == notice, "MCP data access notice stays visible when enabling access")
        try saveScreenshot("mcp-on-\(Int(scale * 100))", in: host)
        host.click(toggle.center)
        let disabled = try !state.library.preferences().mcpEnabled
        check(disabled, "MCP checkbox disables access in the saved library settings")
        check(host.frames[.mcpAccessNotice] == notice, "MCP data access notice stays visible when disabling access")
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

    private func checkMeetingHeader(in host: LayoutHost, titleGap: CGFloat = 16) -> CGRect? {
        if let header = frames([.mainToolbar, .meetingMetadata], in: host) {
            equal(header[1].minY - header[0].maxY, 12, "meeting metadata starts just below the main toolbar")
        }
        guard let measured = frames([.meetingTitle, .meetingContent], in: host) else { return nil }
        equal(measured[1].minY - measured[0].maxY, titleGap, "single gap below the meeting title")
        equal(measured[0].minX, measured[1].minX, "title and meeting content have the same left edge")
        return measured[0]
    }

    private func checkTranscriptionProgress(in host: LayoutHost) -> (heading: CGRect, action: CGRect, progress: CGRect)? {
        let elements: [InterfaceLayoutElement] = [.transcriptionStatusHeading, .transcriptionStatusAction,
                                                   .transcriptionProgressCaption, .transcriptionProgressRow]
        guard let measured = frames(elements, in: host) else { return nil }
        let (heading, action, caption, progress) = (measured[0], measured[1], measured[2], measured[3])
        equal(caption.minY - max(heading.maxY, action.maxY), 8, "progress group starts below the status and actions")
        equal(progress.minY - caption.maxY, 4, "progress caption sits directly above its bar")
        equal(progress.minX, caption.minX, "progress caption and bar align")
        return (heading, action, progress)
    }

    private func checkTranscript(in host: LayoutHost, wide: Bool) {
        let action: InterfaceLayoutElement = wide ? .firstMeetingAction : .detailsButton
        guard let collapsed = frames([.transcriptSearch, action, .meetingContent, .audioToggle], in: host) else { return }
        checkSavedAudioAlignment(in: host, state: "closed")
        equal(collapsed[0].minY, collapsed[1].minY, "search and meeting actions start on the same horizontal line")
        equal(collapsed[0].minY, collapsed[2].minY, "search starts directly below the title gap when the player is closed")
        check(host.frames[.waveform] == nil, "saved player starts closed")
        check(host.frames[wide ? .detailsButton : .firstMeetingAction] == nil, "details switch between column and button at this width")

        host.click(collapsed[3].center)
        if let expanded = frames([.transcriptSearch, action, .meetingContent, .waveform], in: host) {
            checkSavedAudioAlignment(in: host, state: "open")
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

    private func checkSavedAudioAlignment(in host: LayoutHost, state: String) {
        guard let measured = frames([.audioToggle, .audioToggleLabel], in: host) else { return }
        guard let difference = host.savedAudioInkOffset(toggle: measured[0], label: measured[1]) else {
            check(false, "saved audio label and chevron are visible with the player \(state)")
            return
        }
        check(abs(difference) <= 1.25,
              "saved audio chevron is visually centered with the label when the player is \(state) (offset \(difference) pt)")
    }

    private func checkSetup(_ setup: ModelSetup, scale: CGFloat) {
        defer { setup.phase = .ready; setup.upgradeDownloadBytes = nil }
        for upgrade in [false, true] {
            setup.upgradeDownloadBytes = upgrade ? 2_509_042_622 : nil
            for phase in [ModelSetup.Phase.available, .ready] {
                scenario = "model \(upgrade ? "upgrade" : "setup") \(phase), \(Int(scale * 100))%"
                setup.phase = phase
                let host = LayoutHost(ModelSetupView(setup: setup, onReady: {}), size: CGSize(width: 600, height: 660), scale: scale)
                defer { host.close() }
                if let measured = frames([.setupStatus, .setupAction], in: host) {
                    equal(measured[1].minY - measured[0].maxY, 24, "setup status has one section gap before the primary button")
                    check(measured[1].maxY <= host.bounds.maxY, "primary action remains inside the window")
                }
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
            if let tabFrames = frames(tabs.map(InterfaceLayoutElement.settingsTab), in: host),
               let tabBar = frames([.settingsTabBar], in: host)?.first {
                check(zip(tabFrames, tabFrames.dropFirst()).allSatisfy { left, right in left.maxX <= right.minX },
                      "settings tabs appear in order without overlapping")
                check(tabFrames.allSatisfy { host.bounds.contains($0) }, "all settings tabs fit in the window")
                for (tab, frame) in zip(tabs, tabFrames) {
                    scenario = "settings \(tab), \(Int(scale * 100))%"
                    host.click(frame.center)
                    if let content = frames([.settingsContent(tab)], in: host)?.first {
                        equal(content.minY - tabBar.maxY, PisaDesign.Spacing.section,
                              "settings content starts one section gap below the tabs")
                        if tab == "Хранилище",
                           let columns = frames([.settingsStorageUsage, .settingsStorageCleanup], in: host) {
                            let (usage, cleanup) = (columns[0], columns[1])
                            equal(usage.minY, cleanup.minY, "storage sections start at the same height")
                            equal(usage.width, cleanup.width, "storage columns have the same width")
                            equal(cleanup.minX - usage.maxX, 2 * PisaDesign.Spacing.section + 1,
                                  "storage usage is to the left of cleanup with the standard divider spacing")
                            check(columns.allSatisfy { host.bounds.contains($0) }, "both storage sections fit in settings")
                            if let buttons = frames([.settingsStorageAge, .settingsStorageAction], in: host) {
                                check(buttons.allSatisfy { cleanup.contains($0) }, "cleanup buttons fit the right column")
                                for button in buttons {
                                    equal(button.height, PisaDesign.Metrics.regularHeight, "cleanup button labels stay on one line")
                                }
                            }
                        }
                    }
                }
                scenario = "dictionary form, \(Int(scale * 100))%"
                host.click(tabFrames[3].center)
            }
            if let measured = frames([.dictionarySearch, .dictionaryEntry, .dictionaryAdd, .dictionaryResult], in: host) {
                checkFormRow(measured.prefix(3))
                let heading = frames([.dictionaryHeading], in: host)?.first
                if let heading {
                    equal(measured[0].minY - heading.maxY, PisaDesign.Spacing.content,
                          "dictionary search starts directly below the heading")
                }
                let entries = VocabularyDictionary.entries(in: state.preferences.vocabulary)
                let rows = entries.map { InterfaceLayoutElement.dictionaryRow($0.id) }
                if let rowFrames = frames(rows, in: host) {
                    equal(rowFrames[0].minY - measured[0].maxY, PisaDesign.Spacing.content,
                          "dictionary rows start one content gap below the search")
                    let expectedHeight = PisaDesign.Metrics.smallHeight + 2 * PisaDesign.Spacing.compact
                    equal(rowFrames[0].height, expectedHeight, "a short dictionary row uses compact vertical padding")
                    equal(rowFrames[1].minY - rowFrames[0].maxY, PisaDesign.Spacing.compact,
                          "dictionary rows have compact spacing")
                    equal(rowFrames[0].maxX - measured[3].maxX,
                          PisaDesign.Metrics.smallHeight + 2 * PisaDesign.Spacing.related,
                          "dictionary text leaves room for one compact action control")

                    let text = CGPoint(x: measured[3].minX + 8, y: measured[3].midY)
                    for (point, entry) in [(text, entries[0]), (rowFrames[1].center, entries[1])] {
                        host.click(point)
                        check(host.wait { host.sheetContainsField(value: entry.text) },
                              "clicking dictionary row opens the editor with \(entry.text)")
                        if host.hasSheet { host.pressKey("\u{1b}", keyCode: 53) }
                        check(host.wait { !host.hasSheet }, "Escape closes the dictionary editor")
                    }
                }
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
                if let heading {
                    equal(host.frames[.dictionaryHeading]?.width ?? 0, heading.width,
                          "search does not change the total dictionary count")
                    let vocabulary = state.preferences.vocabulary
                    defer { state.preferences.vocabulary = vocabulary }
                    state.preferences.vocabulary = vocabulary + (1...10).map { "\nТермин \($0)" }.joined()
                    check(host.wait { (host.frames[.dictionaryHeading]?.width ?? 0) > heading.width },
                          "dictionary heading widens when the total gains a digit")
                    equal(host.frames[.dictionaryHeading]?.height ?? 0, heading.height,
                          "the total fits on the dictionary subtitle line")
                }
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

    func checkModelSettings(state: AppState, scale: CGFloat) async throws {
        scenario = "model settings, \(Int(scale * 100))%"
        let previousPath = state.preferences.parakeetModelDisplayPath
        state.preferences.parakeetModelDisplayPath = "/Volumes/External Drive/" +
            String(repeating: "Long folder name/", count: 5) + "Parakeet-TDT-v3"
        state.modelSetup.phase = .ready
        let host = LayoutHost(SettingsView(initialSection: "Модель").environmentObject(state),
                              size: CGSize(width: 900, height: 700), scale: scale)
        defer {
            host.close()
            state.preferences.parakeetModelDisplayPath = previousPath
            state.modelSetup.phase = .ready
        }
        func capture(_ name: String) throws {
            guard let path = ProcessInfo.processInfo.environment["PISA_MODEL_SETTINGS_SCREENSHOTS"] else { return }
            let file = "model-\(name)-\(Int(scale * 100)).png"
            try host.savePNG(to: URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(file))
        }
        guard let measured = frames([.settingsContent("Модель"), .settingsModelHeading,
                                     .settingsModelAction, .settingsModelFolder], in: host) else { return }
        let (content, heading, action, folder) = (measured[0], measured[1], measured[2], measured[3])
        equal(heading.minY, content.minY, "model name and status start at the top")
        equal(action.minY - heading.maxY, PisaDesign.Spacing.content, "model action follows the status")
        check(host.frames[.settingsModelDownloadSize] == nil, "installed models have no download size")
        equal(folder.minY - action.maxY, PisaDesign.Spacing.section, "the folder section follows the model action")
        if let visibleFolder = frames([.settingsModelPath, .settingsModelChooseFolder], in: host) {
            equal(visibleFolder[0].minY - folder.maxY, PisaDesign.Spacing.related, "path is visible below the folder heading when settings open")
            equal(visibleFolder[1].minY - visibleFolder[0].maxY, PisaDesign.Spacing.related, "picker sits below the complete path")
            check(visibleFolder.allSatisfy { host.bounds.contains($0) && $0.maxX <= content.midX },
                  "the long path and picker fit the left column")
        }
        try capture("ready")

        host.click(action.center)
        let checked = try await waitForModelSettings { state.modelSetup.phase == .available }
        check(checked, "checking models detects missing files from settings")
        check(!state.modelSetup.presented, "checking models keeps the result in settings")
        if let missing = frames([.settingsModelAction, .settingsModelDownloadSize, .settingsModelFolder], in: host) {
            equal(missing[1].minY - missing[0].maxY, PisaDesign.Spacing.inline, "size sits below the download action")
            equal(missing[2].minY - missing[1].maxY, PisaDesign.Spacing.section, "size stays grouped with the download action")
        }
        state.preferences.parakeetModelDisplayPath = nil
        check(host.wait { host.frames[.settingsModelPath] == nil }, "there is no path when a model folder is unavailable")
        if let missingFolder = frames([.settingsModelFolder, .settingsModelChooseFolder], in: host) {
            equal(missingFolder[1].minY - missingFolder[0].maxY, PisaDesign.Spacing.related,
                  "the picker is visible below the heading without a selected model folder")
        }
        try capture("missing")
        if let download = host.frames[.settingsModelAction] {
            host.click(download.center)
            let opened = try await waitForModelSettings { state.modelSetup.presented && !state.modelSetup.busy }
            check(opened, "the download action opens the model setup flow")
            state.modelSetup.dismiss()
        }
    }

    private func waitForModelSettings(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    private func checkScreenFields(state: AppState, meeting: Meeting, voiceMeeting: Meeting,
                                   savedVoice: VoiceProfile, scale: CGFloat) throws {
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
                    let prefix = String(savedVoice.name.prefix(3))
                    let suggestion = InterfaceLayoutElement.voiceSuggestion(savedVoice.name)
                    let closedToggle = frames([.voiceAllMatching], in: host)?.first
                    check(host.type(prefix, into: name), "voice name accepts a suggestion prefix")
                    if let open = frames([.voiceAllMatching, suggestion], in: host), let closedToggle {
                        equal(open[0].minY, closedToggle.minY, "opening suggestions leaves the form in place")
                        check(open[1].minY >= frame.maxY, "suggestion appears below the name field")
                        check(open[1].intersects(open[0]), "suggestion covers the form")
                        let fieldCenter = host.center(of: name)
                        // HSplitView reports these frames in the right pane's coordinate space.
                        host.click(CGPoint(x: fieldCenter.x + open[1].midX - frame.midX,
                                           y: fieldCenter.y + open[1].midY - frame.midY))
                        check(host.wait { name.currentEditor()?.string == savedVoice.name }, "clicking the overlay fills the name")
                        check(host.frames[suggestion] == nil, "clicking a suggestion closes the overlay")
                        check(host.type(prefix, into: name), "editing the chosen name opens suggestions again")
                    }
                    host.pressKey("\u{1b}", keyCode: 53)
                    check(host.frames[suggestion] == nil, "Escape closes the overlay")
                    check(host.isEditing(name), "Escape leaves the name field focused")
                    if let closedToggle, let restored = host.frames[.voiceAllMatching] {
                        equal(restored.minY, closedToggle.minY, "closing suggestions leaves the form in place")
                    }
                    check(host.type(prefix + "П", into: name), "typing again reopens suggestions")
                    host.pressKey("\t", keyCode: 48)
                    check(host.frames[suggestion] == nil, "Tab closes suggestions before moving to the next control")
                    check(!host.isEditing(name), "Tab moves focus away from the name field")
                    check(host.type(prefix, into: name), "returning to the field allows suggestions again")
                    host.pressKey("\u{19}", keyCode: 48, modifiers: .shift)
                    check(host.frames[suggestion] == nil, "Shift-Tab closes suggestions before moving to the previous control")
                    check(!host.isEditing(name), "Shift-Tab moves focus away from the name field")
                    check(host.type(prefix + "П", into: name), "typing again reopens suggestions")
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
            let secondVoice = VoiceProfile(name: "Ярослав", samples: [])
            let previousProfiles = state.voiceProfiles
            state.voiceProfiles = [savedVoice, secondVoice]
            let host = LayoutHost(SettingsView(initialSection: "Голоса").environmentObject(state),
                                  size: CGSize(width: 900, height: 700), scale: scale)
            defer {
                host.close()
                state.voiceProfiles = previousProfiles
            }
            if let measured = frames([.savedVoiceHeading, .savedVoiceSearch,
                                      .savedVoiceRow(savedVoice.id), .savedVoiceRow(secondVoice.id)], in: host) {
                equal(measured[1].minY - measured[0].maxY, PisaDesign.Spacing.content,
                      "saved voice search starts directly below the heading")
                equal(measured[2].minY - measured[1].maxY, PisaDesign.Spacing.content,
                      "saved voice rows start one content gap below the search")
                equal(measured[3].minY - measured[2].maxY, PisaDesign.Spacing.related,
                      "saved voice rows have room between groups")
            }
            let fullHeading = host.frames[.savedVoiceHeading]
            try saveScreenshot("saved-people-full-\(percent)", in: host)
            checkField(.savedVoiceSearch, placeholder: true, value: "ПППППП", in: host)
            if let heading = fullHeading, let searchFrame = host.frames[.savedVoiceSearch],
               let search = host.field(in: searchFrame, placeholder: "Найти голос по имени") {
                check(host.frames[.savedVoiceHeading] == heading, "the first search preserves the saved people count")
                check(host.type(secondVoice.name, into: search), "search accepts a saved voice name")
                check(host.wait { host.frames[.savedVoiceRow(savedVoice.id)] == nil && host.frames[.savedVoiceRow(secondVoice.id)] != nil },
                      "search leaves only the matching voice visible")
                check(host.frames[.savedVoiceHeading] == heading, "search preserves the saved people count")
                try saveScreenshot("saved-people-filtered-\(percent)", in: host)
                state.voiceProfiles = [secondVoice]
                check(host.wait { (host.frames[.savedVoiceHeading]?.width ?? heading.width) < heading.width },
                      "the heading updates from two people to one after a profile is removed")
                try saveScreenshot("saved-people-one-\(percent)", in: host)
                state.voiceProfiles = []
                check(host.wait { host.frames[.savedVoiceSearch] == nil }, "removing the last profile shows the empty state")
                try saveScreenshot("saved-people-empty-\(percent)", in: host)
            } else {
                check(false, "saved voices show the heading and search field")
            }
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
    var hasSheet: Bool { window.attachedSheet != nil }

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

    func center(of field: NSTextField) -> CGPoint {
        let rect = field.convert(field.bounds, to: view)
        return CGPoint(x: rect.midX, y: view.isFlipped ? rect.midY : view.bounds.height - rect.midY)
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
                    if frame.contains(center(of: field)) { return field }
                }
            }
            return node.subviews.lazy.compactMap { find($0) }.first
        }
        return find(view)
    }

    func pressReturn(settle: Bool = true) { pressKey("\r", keyCode: 36, settle: settle) }

    func pressKey(_ character: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], settle: Bool = true) {
        let target = window.attachedSheet ?? window
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: target.windowNumber, context: nil, characters: character,
                                            charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode) {
                target.sendEvent(event)
            }
        }
        if settle { self.settle() }
    }

    func sheetContainsField(value: String) -> Bool {
        func contains(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.isEditable, field.stringValue == value { return true }
            return view.subviews.contains(where: contains)
        }
        guard let content = window.attachedSheet?.contentView else { return false }
        return contains(content)
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

    func savePNG(to url: URL) throws {
        settle()
        guard let image = renderedHost(), let data = image.representation(using: .png, properties: [:]) else {
            throw PisaError.message("Не удалось создать изображение интерфейса")
        }
        try data.write(to: url, options: .atomic)
    }

    // Read only pixels from the synthetic host, in memory. No desktop capture.
    private func renderedHost() -> NSBitmapImageRep? {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: image)
        return image
    }

    func savedAudioInkOffset(toggle: CGRect, label: CGRect) -> CGFloat? {
        guard let image = renderedHost() else { return nil }
        let sx = CGFloat(image.pixelsWide) / bounds.width
        let sy = CGFloat(image.pixelsHigh) / bounds.height

        func inkCenter(in rect: CGRect) -> CGFloat? {
            let left = max(0, Int(floor(rect.minX * sx)))
            let right = min(image.pixelsWide, Int(ceil(rect.maxX * sx)))
            let top = max(0, Int(floor(rect.minY * sy)))
            let bottom = min(image.pixelsHigh, Int(ceil(rect.maxY * sy)))
            guard left < right, top < bottom else { return nil }
            var totalY = 0
            var count = 0
            for y in top..<bottom {
                for x in left..<right {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                          color.greenComponent - color.redComponent > 0.12,
                          color.greenComponent - color.blueComponent > 0.10 else { continue }
                    totalY += y
                    count += 1
                }
            }
            return count > 0 ? CGFloat(totalY) / CGFloat(count) / sy : nil
        }

        let chevron = CGRect(x: label.maxX, y: toggle.minY, width: toggle.maxX - label.maxX, height: toggle.height)
        guard let labelCenter = inkCenter(in: label), let chevronCenter = inkCenter(in: chevron) else { return nil }
        return chevronCenter - labelCenter
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
