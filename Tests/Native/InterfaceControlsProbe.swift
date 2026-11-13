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
    @Published var compactSearch = "ПППППП"
    @Published var notes = "Первая строка\nВторая строка"
    @Published var section = "Запись"
    @Published var frames: [String: CGRect] = [:]
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

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) {
            HStack(spacing: PisyaDesign.Spacing.related) {
                FormTextField(title: "Filled name", text: $fixture.name).measured("name")
                FormTextField(title: "ПППППП", text: $fixture.emptyName).measured("empty-name")
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                SearchField(title: "Filled search", text: $fixture.search).measured("search")
                SearchField(title: "ПППППП", text: $fixture.emptySearch).measured("empty-search")
            }
            SearchField(title: "Поиск в библиотеке", text: $fixture.compactSearch, compact: true)
                .measured("compact-search")
            HStack(spacing: PisyaDesign.Spacing.related) {
                button("primary", role: .primary)
                button("secondary", role: .secondary)
                button("recording", role: .recording)
                screenButton("ПППППП") {}
                    .actionButton().disabled(true).measured("disabled")
                screenButton("ПППППП") {}
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
        screenButton("ПППППП") {}
            .actionButton(role).measured(id)
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

    func capture(_ host: NSView, evidence: String? = nil) -> NSBitmapImageRep? {
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            check(false, "Cannot allocate an image of the test view")
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: image)
        if let output, let evidence, let data = image.representation(using: .png, properties: [:]) {
            do { try data.write(to: output.appendingPathComponent(evidence + ".png")) }
            catch { check(false, "Cannot save evidence: \(error)") }
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
        // Preserve AppKit's back-tab character when dispatching Shift+Tab.
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text,
                isARepeat: false, keyCode: keyCode) else {
                check(false, "Could not construct synthetic key event")
                return
            }
            window.sendEvent(event)
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
        // The focused and unfocused rasterizers can differ by one pixel at a
        // glyph edge. Keep the tolerance below a full point on Retina.
        let pixelsPerPoint = CGFloat(image.pixelsHigh) / host.bounds.height
        let tolerance = min(0.5, 1 / pixelsPerPoint)
        // Compare the glyph baseline edge. At 1× the top antialiased row can
        // disappear while the baseline and the field's frame stay fixed.
        return abs(first.minX - second.minX) <= tolerance
            && abs(first.maxY - second.maxY) <= tolerance
    }

    func checkFocus(_ field: NSTextField, id: String, fixture: ControlsFixture,
                    window: NSWindow, host: NSView, prefix: String) {
        window.makeFirstResponder(nil)
        pump(host)
        let beforeFrame = fixture.frames[id]
        let nativeRect = topRect(field, in: host)
        let sample = field.stringValue.isEmpty
            ? (field.placeholderString ?? field.placeholderAttributedString?.string ?? "") : field.stringValue
        guard let font = field.font else { check(false, "\(prefix)/\(id): native font exists"); return }
        let textWidth = (sample as NSString).size(withAttributes: [.font: font]).width
        // Ignore the caret at either edge. Keep this same fixed crop for focused
        // and blurred captures, otherwise an offset in the view would be hidden.
        let region = CGRect(x: nativeRect.minX + 4, y: nativeRect.minY - 4,
                            width: max(1, textWidth - 8), height: nativeRect.height + 8)
        guard let before = capture(host, evidence: "\(prefix)-\(id)-blur"),
              let beforeInk = inkBounds(before, in: region, host: host) else {
            check(false, "\(prefix)/\(id): unfocused text/placeholder is actually rendered")
            return
        }
        guard focus(field, window: window, host: host, label: "\(prefix)/\(id)") != nil,
              let focused = capture(host, evidence: "\(prefix)-\(id)-focus"),
              let focusedInk = inkBounds(focused, in: region, host: host) else {
            check(false, "\(prefix)/\(id): focused text/placeholder is actually rendered")
            return
        }
        check(sameOrigin(beforeInk, focusedInk, image: before, host: host),
              "\(prefix)/\(id): text origin moved on focus: \(beforeInk) -> \(focusedInk)")
        check(fixture.frames[id] == beforeFrame, "\(prefix)/\(id): focus resized the control")
        window.makeFirstResponder(nil)
        pump(host)
        if let after = capture(host),
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

    private func checkButtonFocus(_ fixture: ControlsFixture, after field: NSTextField, window: NSWindow,
                                  host: NSView, prefix: String) {
        // The last search field precedes the primary action when its query is
        // empty. Its clear button would otherwise be the next keyboard stop.
        fixture.compactSearch = ""
        window.makeFirstResponder(nil)
        pump(host)
        guard let frame = fixture.frames["primary"], let neutral = capture(host),
              focus(field, window: window, host: host, label: "\(prefix)/actions") != nil else { return }
        send("\t", keyCode: 48, window: window)
        pump(host)
        guard let focused = capture(host) else { return }
        check(fixture.frames["primary"] == frame, "\(prefix): primary action stays the same size on focus")
        check(exteriorChanges(neutral, focused, frame: frame, host: host) == 0,
              "\(prefix): focus does not paint outside the primary action")
        let x = Int((frame.minX + 5) * CGFloat(neutral.pixelsWide) / host.bounds.width)
        let y = Int(frame.midY * CGFloat(neutral.pixelsHigh) / host.bounds.height)
        guard let normal = neutral.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
              let highlight = focused.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            check(false, "\(prefix): focus fill pixels were available")
            return
        }
        let difference = abs(normal.redComponent - highlight.redComponent)
            + abs(normal.greenComponent - highlight.greenComponent)
            + abs(normal.blueComponent - highlight.blueComponent)
        check(difference > 0.02, "\(prefix): Tab shows primary action focus as a changed fill")
        window.makeFirstResponder(nil)
        pump(host)
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
        defer { window.close() }
        pump(host, for: 0.3)
        window.makeFirstResponder(nil)
        pump(host)

        let nativeFields = allViews(host).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let ids = ["name", "empty-name", "search", "empty-search", "compact-search"]
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
            let expectedSize: CGFloat = id == "compact-search" ? 12 : 16
            check(abs((field.font?.pointSize ?? 0) - expectedSize * scale) < 0.1,
                  "\(prefix)/\(id): field uses its intended text size")
            checkFocus(field, id: id, fixture: fixture, window: window, host: host, prefix: prefix)
        }

        let regularIDs = ["name", "empty-name", "search", "empty-search", "primary", "secondary", "recording", "disabled"]
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

        if let image = capture(host),
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

        checkButtonFocus(fixture, after: fields[4], window: window, host: host, prefix: prefix)

        let tabSize = fixture.frames["tabs"]?.size
        for title in ["Модель", "Голоса", "Словарь", "Экспорт", "MCP", "Обновления", "Запись"] {
            fixture.section = title
            pump(host)
            check(fixture.frames["tabs"]?.size == tabSize,
                  "\(prefix): selecting \(title) does not resize the settings tabs")
        }

        guard let editor = allViews(host).compactMap({ $0 as? NSTextView }).first(where: { $0.isEditable && !$0.isFieldEditor }) else {
            check(false, "\(prefix): native multiline editor exists")
            return
        }
        guard let editorFrame = fixture.frames["editor"] else {
            check(false, "\(prefix): multiline editor frame exists")
            return
        }
        let firstLines = CGRect(x: editorFrame.minX + 20, y: editorFrame.minY + 6,
                                width: 180, height: 65)
        let before = capture(host)
        check(window.makeFirstResponder(editor), "\(prefix): multiline editor accepts focus")
        pump(host)
        check(fixture.frames["editor"] == editorFrame, "\(prefix): multiline focus preserves geometry")
        if let before, let focused = capture(host),
           let beforeInk = inkBounds(before, in: firstLines, host: host),
           let focusedInk = inkBounds(focused, in: firstLines, host: host) {
            check(sameOrigin(beforeInk, focusedInk, image: before, host: host),
                  "\(prefix): multiline text origin is stable on focus")
        } else {
            check(false, "\(prefix): multiline text is rendered before and after focus")
        }
        check(abs((editor.font?.pointSize ?? 0) - 16 * scale) < 0.1, "\(prefix): multiline editor shares the form body font")
        editor.selectAll(nil)
        let longText = (1...80).map { "Строка \($0) — проверка прокрутки" }.joined(separator: "\n")
        editor.insertText(longText, replacementRange: editor.selectedRange()); pump(host)
        check(fixture.notes == longText, "\(prefix): multiline native edits reach the binding without truncation")
        editor.scrollRangeToVisible(NSRange(location: (editor.string as NSString).length, length: 0)); pump(host)
        check((editor.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0, "\(prefix): the final multiline text is reachable by scrolling")
        window.makeFirstResponder(nil); pump(host)
        check(fixture.notes == longText, "\(prefix): multiline blur does not discard the draft")
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
        if CommandLine.arguments.count != 1 {
            guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render" else {
                fputs("Usage: interface-controls-probe [--render DIRECTORY]\n", stderr)
                exit(2)
            }
            let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { fputs("Cannot create evidence directory: \(error)\n", stderr); exit(2) }
            output = directory
        }
        let probe = Probe(output: output)
        for percent in [100, 110, 120] {
            for size in [ControlSize.regular, .large] {
                probe.test(scale: AppTextSize.factor(for: percent), controlSize: size)
            }
        }
        print("INTERFACE_CONTROLS_TEST_RESULT checks=\(probe.checks) failures=\(probe.failures)")
        print("LIMITATION: synthetic control harness; Space activation, full app screens and physical input require separate verification")
        exit(probe.failures == 0 && probe.checks > 0 ? 0 : 1)
    }
}
