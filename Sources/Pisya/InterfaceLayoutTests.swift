import AppKit
import AVFoundation
import SwiftUI

// Attach passive measurements only when a test host supplies the named space.
enum InterfaceLayoutElement: Hashable {
    case welcomeContent, welcomeTitle, welcomeDescription, welcomeAction
    case meetingTitle, meetingContent, meetingStatus, audioToggle, waveform
    case transcriptSearch, firstMeetingAction, detailsButton
    case setupStatus, setupAction
    case microphoneLabel, systemAudioLabel, microphoneWarning, systemAudioWarning
    case settingsTab(String)
    case dictionarySearch, dictionaryEntry, dictionaryAdd, dictionaryResult
    case termSearch, termFind
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
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Interface-Tests-" + UUID().uuidString)
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
            throw PisyaError.message("Could not create the synthetic audio fixture")
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
        for scale in [1.0, 1.2] {
            checkSetup(state.modelSetup, scale: scale)
            checkRecordingLevels(state.recordingMonitor, scale: scale)
            checkForms(state: state, meeting: ready, scale: scale)
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
            let tabs = ["Запись", "Модель", "Голоса", "Словарь", "Экспорт", "MCP", "Обновления"]
            if let tabFrames = frames(tabs.map(InterfaceLayoutElement.settingsTab), in: host) {
                check(zip(tabFrames, tabFrames.dropFirst()).allSatisfy { left, right in left.maxX <= right.minX },
                      "settings tabs appear in order without overlapping")
                check(tabFrames.allSatisfy { host.bounds.contains($0) }, "all settings tabs fit in the window")
                host.click(tabFrames[3].center)
            }
            if let measured = frames([.dictionarySearch, .dictionaryEntry, .dictionaryAdd, .dictionaryResult], in: host) {
                checkFormRow(measured.prefix(3))
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
        }
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
        window.title = "Pisya · Тест интерфейса"
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

    func field(in frame: CGRect) -> NSTextField? {
        func find(_ node: NSView) -> NSTextField? {
            if let field = node as? NSTextField, field.isEditable {
                let rect = field.convert(field.bounds, to: view)
                let point = CGPoint(x: rect.midX, y: view.isFlipped ? rect.midY : view.bounds.height - rect.midY)
                if frame.contains(point) { return field }
            }
            return node.subviews.lazy.compactMap { find($0) }.first
        }
        return find(view)
    }

    func type(_ text: String, into field: NSTextField) -> Bool {
        guard window.makeFirstResponder(field), let editor = field.currentEditor() else { return false }
        editor.insertText(text)
        settle()
        return field.stringValue == text || editor.string == text
    }

    // Read only pixels from the synthetic host, in memory. No desktop capture.
    func hasYellowHighlight(in frame: CGRect) -> Bool {
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: image)
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
