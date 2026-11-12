import AppKit
import SwiftUI

// This executable hosts the production controls directly. It has no AppState,
// recording service, model, or access to the user's library/preferences.
// Synthetic key events are deliberately not evidence of physical keyboard input.
@MainActor
private final class ControlsFixture: ObservableObject {
    @Published var name = "ПППППП"
    @Published var emptyName = ""
    @Published var search = "ПППППП"
    @Published var emptySearch = ""
    @Published var voice = "ПППППП"
    @Published var notes = "Первая строка\nВторая строка"
    @Published var section = "Запись"
    @Published var frames: [String: CGRect] = [:]
    var activations = 0
}

private struct ControlFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    func measured(_ id: String) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: ControlFrames.self,
                                   value: [id: geometry.frame(in: .named("controls-probe"))])
        })
    }
}

@MainActor
private struct ControlsView: View {
    @ObservedObject var fixture: ControlsFixture
    let scale: CGFloat
    @State private var editingName = false
    @State private var editingEmptyName = false
    @State private var editingVoice = false

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                TextField("Filled name", text: $fixture.name, onEditingChanged: { editingName = $0 })
                    .textFieldStyle(PisyaTextFieldStyle(isEditing: editingName)).measured("name")
                TextField("ПППППП", text: $fixture.emptyName, onEditingChanged: { editingEmptyName = $0 })
                    .textFieldStyle(PisyaTextFieldStyle(isEditing: editingEmptyName)).measured("empty-name")
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                SearchField(title: "Filled search", text: $fixture.search).measured("search")
                SearchField(title: "ПППППП", text: $fixture.emptySearch).measured("empty-search")
            }
            // VoiceManager deliberately uses a different native baseline correction at 110%.
            TextField("Voice name", text: $fixture.voice, onEditingChanged: { editingVoice = $0 })
                .textFieldStyle(PisyaTextFieldStyle(isEditing: editingVoice && scale != AppTextSize.factor(for: 110)))
                .measured("voice")
            HStack(spacing: PisyaDesign.Spacing.related) {
                button("primary", role: .primary)
                button("secondary", role: .secondary)
                button("recording", role: .recording)
                screenButton("ПППППП") { fixture.activations += 1 }
                    .actionButton().disabled(true).accessibilityIdentifier("disabled").measured("disabled")
                screenButton("ПППППП") { fixture.activations += 1 }
                    .actionButton(size: .small).measured("compact")
            }
            SettingsSectionPicker(selection: $fixture.section).fixedSize().measured("tabs")
            FormTextEditor(text: $fixture.notes).measured("editor")
        }
        .padding(PisyaDesign.Spacing.section)
        .frame(width: 900, height: 620, alignment: .topLeading)
        .coordinateSpace(name: "controls-probe")
        .environment(\.appTextScale, scale)
        .background(Color.white)
        .onPreferenceChange(ControlFrames.self) {
            if fixture.frames != $0 { fixture.frames = $0 }
        }
    }

    private func button(_ id: String, role: ActionButtonRole) -> some View {
        screenButton("ПППППП") { fixture.activations += 1 }
            .actionButton(role).accessibilityIdentifier(id).measured(id)
    }
}

@MainActor
private final class Probe {
    private(set) var checks = 0
    private(set) var failures = 0
    let output: URL?

    init(output: URL?) { self.output = output }

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            fputs("FAIL: \(message)\n", stderr)
        }
    }

    func pump(_ host: NSView, for seconds: TimeInterval = 0.12) {
        let until = Date().addingTimeInterval(seconds)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: min(until, Date().addingTimeInterval(0.01)))
        } while Date() < until
        host.displayIfNeeded()
    }

    func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews)
    }

    func accessibleControl(_ id: String, in root: NSView) -> (any NSAccessibilityProtocol)? {
        var queue: [Any] = [root]
        var seen: Set<ObjectIdentifier> = []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard let element = next as? any NSAccessibilityProtocol,
                  seen.insert(ObjectIdentifier(element)).inserted else { continue }
            if element.accessibilityIdentifier() == id { return element }
            // AppKit may flatten or omit ignored hosting containers in the AX
            // tree. Walk their real views too; identity de-duplication prevents
            // checking a control twice when both routes expose it.
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
            queue.append(contentsOf: element.accessibilityChildren() ?? [])
        }
        return nil
    }

    func capture(_ host: NSView, name: String) -> NSBitmapImageRep? {
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            check(false, "\(name): cannot allocate rendered control image")
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: image)
        if let output, let data = image.representation(using: .png, properties: [:]) {
            do { try data.write(to: output.appendingPathComponent(name + ".png")) }
            catch { check(false, "\(name): cannot save evidence: \(error)") }
        }
        return image
    }

    // Geometry preferences have a top-left origin. NSBitmapImageRep's colorAt also
    // uses image rows, irrespective of the hosting view's AppKit flipped state.
    func inkBounds(_ image: NSBitmapImageRep, in region: CGRect, host: NSView) -> CGRect? {
        let sx = CGFloat(image.pixelsWide) / host.bounds.width
        let sy = CGFloat(image.pixelsHigh) / host.bounds.height
        let left = max(0, Int(floor(region.minX * sx)))
        let right = min(image.pixelsWide, Int(ceil(region.maxX * sx)))
        let top = max(0, Int(floor(region.minY * sy)))
        let bottom = min(image.pixelsHigh, Int(ceil(region.maxY * sy)))
        guard left < right, top < bottom else { return nil }
        var minX = right, minY = bottom, maxX = -1, maxY = -1
        for y in top..<bottom {
            for x in left..<right {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                // All channels must be dark; colored focus rings and the caret's
                // blue accent do not count as black/gray text.
                if color.alphaComponent > 0.8 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.74 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: CGFloat(minX) / sx, y: CGFloat(minY) / sy,
                      width: CGFloat(maxX - minX + 1) / sx, height: CGFloat(maxY - minY + 1) / sy)
    }

    func topRect(_ view: NSView, in host: NSView) -> CGRect {
        let rect = view.convert(view.bounds, to: host)
        return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    func send(_ text: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], window: NSWindow) {
        // Shift+Tab has a back-tab character, but its unmodified character is
        // still Tab. Space activation can occur on release in SwiftUI, so every
        // synthetic press must contain both halves of the native key sequence.
        let unmodified = keyCode == 48 ? "\t" : text
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: unmodified,
                isARepeat: false, keyCode: keyCode) else {
                check(false, "Could not construct synthetic key event")
                return
            }
            NSApp.sendEvent(event)
        }
    }

    func focus(_ field: NSTextField, window: NSWindow, host: NSView, label: String) -> NSTextView? {
        check(window.makeFirstResponder(field), "\(label): field accepts keyboard focus")
        field.selectText(nil)
        pump(host)
        guard let editor = field.currentEditor() as? NSTextView, window.firstResponder === editor else {
            check(false, "\(label): actual native field editor became first responder")
            return nil
        }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        pump(host)
        return editor
    }

    func sameOrigin(_ first: CGRect, _ second: CGRect, image: NSBitmapImageRep, host: NSView) -> Bool {
        // Under one physical pixel, so a one-point historical baseline jump fails
        // at both 1x and 2x. Whole-view screenshots remain available for diagnosis.
        let tolerance = 0.6 / (CGFloat(image.pixelsHigh) / host.bounds.height)
        return abs(first.minX - second.minX) <= tolerance && abs(first.minY - second.minY) <= tolerance
    }

    func checkFocus(_ field: NSTextField, id: String, fixture: ControlsFixture,
                    window: NSWindow, host: NSView, prefix: String) {
        window.makeFirstResponder(nil)
        pump(host)
        let beforeFrame = fixture.frames[id]
        let nativeRect = topRect(field, in: host)
        let sample = field.stringValue.isEmpty ? (field.placeholderString ?? "") : field.stringValue
        guard let font = field.font else { check(false, "\(prefix)/\(id): native font exists"); return }
        let textWidth = (sample as NSString).size(withAttributes: [.font: font]).width
        // Ignore the caret at either edge. Keep this same fixed crop for focused
        // and blurred captures, otherwise an offset in the view would be hidden.
        let region = CGRect(x: nativeRect.minX + 4, y: nativeRect.minY - 4,
                            width: max(1, textWidth - 8), height: nativeRect.height + 8)
        guard let before = capture(host, name: "\(prefix)-\(id)-blur"),
              let beforeInk = inkBounds(before, in: region, host: host) else {
            check(false, "\(prefix)/\(id): unfocused text/placeholder is actually rendered")
            return
        }
        guard focus(field, window: window, host: host, label: "\(prefix)/\(id)") != nil,
              let focused = capture(host, name: "\(prefix)-\(id)-focus"),
              let focusedInk = inkBounds(focused, in: region, host: host) else {
            check(false, "\(prefix)/\(id): focused text/placeholder is actually rendered")
            return
        }
        check(sameOrigin(beforeInk, focusedInk, image: before, host: host),
              "\(prefix)/\(id): text origin moved on focus: \(beforeInk) -> \(focusedInk)")
        check(fixture.frames[id] == beforeFrame, "\(prefix)/\(id): focus resized the control")
        window.makeFirstResponder(nil)
        pump(host)
        if let after = capture(host, name: "\(prefix)-\(id)-blur-again"),
           let afterInk = inkBounds(after, in: region, host: host) {
            check(sameOrigin(beforeInk, afterInk, image: before, host: host),
                  "\(prefix)/\(id): text origin changed after ending editing")
        } else { check(false, "\(prefix)/\(id): text remained visible after blur") }
    }

    func exteriorChanges(_ before: NSBitmapImageRep, _ after: NSBitmapImageRep,
                         frame: CGRect, host: NSView) -> Int {
        let sx = CGFloat(before.pixelsWide) / host.bounds.width
        let sy = CGFloat(before.pixelsHigh) / host.bounds.height
        let region = frame.insetBy(dx: -7, dy: -7)
        var changes = 0
        for y in max(0, Int(region.minY * sy))..<min(before.pixelsHigh, Int(region.maxY * sy)) {
            for x in max(0, Int(region.minX * sx))..<min(before.pixelsWide, Int(region.maxX * sx)) {
                let point = CGPoint(x: (CGFloat(x) + 0.5) / sx, y: (CGFloat(y) + 0.5) / sy)
                guard !frame.insetBy(dx: -0.6, dy: -0.6).contains(point),
                      let a = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let b = after.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                       abs(a.blueComponent - b.blueComponent)) > 0.05 { changes += 1 }
            }
        }
        return changes
    }

    func test(scale: CGFloat, controlSize: ControlSize) {
        let prefix = "\(Int((scale * 100).rounded()))-\(controlSize == .large ? "large" : "regular")"
        let fixture = ControlsFixture()
        let host = NSHostingView(rootView: ControlsView(fixture: fixture, scale: scale).controlSize(controlSize))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Pisya isolated controls regression"
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        pump(host, for: 0.3)
        window.makeFirstResponder(nil)
        pump(host)

        let nativeFields = allViews(host).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let ids = ["name", "empty-name", "search", "empty-search", "voice"]
        // A filled native field and its placeholder neighbor can differ by a
        // fractional baseline. Map by the containing production control instead
        // of sorting their raw Y coordinates, which could swap a pair of fields.
        let fields = ids.compactMap { id -> NSTextField? in
            guard let frame = fixture.frames[id] else { return nil }
            return nativeFields.first { field in
                let rect = topRect(field, in: host)
                return frame.contains(CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        let distinctFields = Set(fields.map { ObjectIdentifier($0) }).count
        check(nativeFields.count == ids.count, "\(prefix): found all five real native text fields, got \(nativeFields.count)")
        check(fixture.frames.count == 12, "\(prefix): all control geometry preferences were measured, got \(fixture.frames.keys.sorted())")
        check(fields.count == ids.count && distinctFields == ids.count, "\(prefix): each field maps to one distinct control frame")
        guard nativeFields.count == ids.count, fields.count == ids.count,
              distinctFields == ids.count, fixture.frames.count == 12 else { return }

        for (field, id) in zip(fields, ids) {
            check(abs((field.font?.pointSize ?? 0) - 16 * scale) < 0.1, "\(prefix)/\(id): field uses the form's body font")
            checkFocus(field, id: id, fixture: fixture, window: window, host: host, prefix: prefix)
        }

        let regularIDs = ["name", "empty-name", "search", "empty-search", "voice", "primary", "secondary", "recording", "disabled"]
        for id in regularIDs {
            check(abs((fixture.frames[id]?.height ?? 0) - 36) < 0.5, "\(prefix)/\(id): ordinary form control remains 36 points high")
        }
        check(abs((fixture.frames["compact"]?.height ?? 0) - 32) < 0.5, "\(prefix): compact row action remains distinct from ordinary form controls")

        // Exercise AppKit's actual key-view loop. Direct binding assignment would
        // miss the historical keyboard/focus routing failures entirely.
        if focus(fields[0], window: window, host: host, label: "\(prefix)/Tab") != nil {
            send("\t", keyCode: 48, window: window); pump(host)
            check(fields[1].currentEditor() === window.firstResponder, "\(prefix): Tab moves to the next form field")
            send("\u{19}", keyCode: 48, modifiers: .shift, window: window); pump(host)
            check(fields[0].currentEditor() === window.firstResponder, "\(prefix): Shift+Tab returns to the previous field")
        }
        if let editor = focus(fields[0], window: window, host: host, label: "\(prefix)/editing") {
            editor.selectAll(nil)
            editor.insertText("Исправленное имя", replacementRange: editor.selectedRange())
            pump(host)
            check(fixture.name == "Исправленное имя", "\(prefix): native editing updates the SwiftUI binding")
            window.makeFirstResponder(nil); pump(host)
            check(fixture.name == "Исправленное имя", "\(prefix): blur preserves the edited value")
            fixture.name = "ПППППП"; pump(host)
        }

        if let image = capture(host, name: "\(prefix)-form-typography"),
           let fieldFrame = fixture.frames["name"], let buttonFrame = fixture.frames["secondary"],
           let compactFrame = fixture.frames["compact"],
           let fieldInk = inkBounds(image, in: fieldFrame.insetBy(dx: 12, dy: 3), host: host),
           let buttonInk = inkBounds(image, in: buttonFrame.insetBy(dx: 10, dy: 3), host: host),
           let compactInk = inkBounds(image, in: compactFrame.insetBy(dx: 8, dy: 3), host: host) {
            let pixel = host.bounds.height / CGFloat(image.pixelsHigh)
            check(abs(fieldInk.height - buttonInk.height) <= pixel,
                  "\(prefix): action and input labels have matching rendered cap height: \(fieldInk.height), \(buttonInk.height)")
            check(compactInk.height < buttonInk.height,
                  "\(prefix): negative control detects the deliberately smaller compact label")
        } else { check(false, "\(prefix): form typography pixels were available") }

        for id in ["primary", "secondary", "recording"] {
            window.makeFirstResponder(nil); pump(host)
            guard let frame = fixture.frames[id], let before = capture(host, name: "\(prefix)-\(id)-normal") else { continue }
            guard let control = accessibleControl(id, in: host) else {
                check(false, "\(prefix)/\(id): actual accessible button exists")
                continue
            }
            // Do not add an outer .focused modifier: it would replace the
            // production ControlKeyboardFocus binding and invalidate this test.
            control.setAccessibilityFocused(true); pump(host)
            check(control.isAccessibilityFocused(), "\(prefix)/\(id): keyboard focus is retained")
            guard let focused = capture(host, name: "\(prefix)-\(id)-focused") else { continue }
            check(fixture.frames[id] == frame, "\(prefix)/\(id): focus preserves button geometry")
            check(exteriorChanges(before, focused, frame: frame, host: host) == 0,
                  "\(prefix)/\(id): focus does not paint outside the button")
            let x = Int((frame.minX + 5) * CGFloat(before.pixelsWide) / host.bounds.width)
            let y = Int(frame.midY * CGFloat(before.pixelsHigh) / host.bounds.height)
            if let a = before.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               let b = focused.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                check(abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.02,
                      "\(prefix)/\(id): focus is visible as a changed fill")
            } else { check(false, "\(prefix)/\(id): focus fill pixels were available") }
            let beforeCount = fixture.activations
            send(" ", keyCode: 49, window: window); pump(host)
            check(fixture.activations == beforeCount + 1, "\(prefix)/\(id): keyboard Space still activates the button")
        }
        window.makeFirstResponder(nil); pump(host)
        if let disabled = accessibleControl("disabled", in: host) {
            check(!disabled.isAccessibilityEnabled(), "\(prefix): disabled action is exposed as unavailable")
            let beforeCount = fixture.activations
            _ = disabled.accessibilityPerformPress(); pump(host)
            check(fixture.activations == beforeCount, "\(prefix): disabled action cannot execute")
        } else { check(false, "\(prefix): disabled action remains accessible") }

        let tabSize = fixture.frames["tabs"]?.size
        for title in ["Модель", "Голоса", "Экспорт", "MCP", "Обновления", "Запись"] {
            fixture.section = title; pump(host)
            check(fixture.frames["tabs"]?.size == tabSize, "\(prefix): settings tab selection \(title) does not resize the picker")
        }

        guard let editor = allViews(host).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && !$0.isFieldEditor }) else {
            check(false, "\(prefix): native multiline editor exists")
            return
        }
        let editorFrame = fixture.frames["editor"]
        check(window.makeFirstResponder(editor), "\(prefix): multiline editor accepts focus")
        pump(host)
        check(fixture.frames["editor"] == editorFrame, "\(prefix): multiline focus preserves geometry")
        check(abs((editor.font?.pointSize ?? 0) - 16 * scale) < 0.1, "\(prefix): multiline editor shares the form body font")
        editor.selectAll(nil)
        let longText = (1...80).map { "Строка \($0) — проверка прокрутки" }.joined(separator: "\n")
        editor.insertText(longText, replacementRange: editor.selectedRange()); pump(host)
        check(fixture.notes == longText, "\(prefix): multiline native edits reach the binding without truncation")
        editor.scrollRangeToVisible(NSRange(location: (editor.string as NSString).length, length: 0)); pump(host)
        check((editor.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0, "\(prefix): the final multiline text is reachable by scrolling")
        window.makeFirstResponder(nil); pump(host)
        check(fixture.notes == longText, "\(prefix): multiline blur does not discard the draft")
        _ = capture(host, name: "\(prefix)-multiline-end")
        print("CONTROLS_CASE_DONE scale=\(Int((scale * 100).rounded())) control=\(controlSize == .large ? "large" : "regular")")
    }
}

@main
enum InterfaceControlsProbe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        guard NSScreen.main != nil else {
            fputs("BLOCKED: native interface checks require a macOS WindowServer session\n", stderr)
            exit(77)
        }
        app.finishLaunching()
        var output: URL?
        if let index = CommandLine.arguments.firstIndex(of: "--render") {
            guard CommandLine.arguments.indices.contains(index + 1) else {
                fputs("Usage: interface-controls-probe [--render DIRECTORY]\n", stderr); exit(2)
            }
            output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            do { try FileManager.default.createDirectory(at: output!, withIntermediateDirectories: true) }
            catch { fputs("Cannot create evidence directory: \(error)\n", stderr); exit(2) }
        }
        let probe = Probe(output: output)
        for percent in [100, 110, 120] {
            for size in [ControlSize.regular, .large] {
                probe.test(scale: AppTextSize.factor(for: percent), controlSize: size)
            }
        }
        print("INTERFACE_CONTROLS_TEST_RESULT checks=\(probe.checks) failures=\(probe.failures)")
        print("LIMITATION: synthetic control harness; full-screen app states and physical keyboard require separate verification")
        exit(probe.failures == 0 && probe.checks > 0 ? 0 : 1)
    }
}
