import SwiftUI
import AppKit

/// Let a click on non-editable content end field editing without consuming the click.
struct ClickToUnfocus: NSViewRepresentable {
    var onEscape: (() -> Bool)?

    func makeNSView(context: Context) -> FocusObserver { FocusObserver() }
    func updateNSView(_ nsView: FocusObserver, context: Context) { nsView.onEscape = onEscape }

    final class FocusObserver: NSView {
        var onEscape: (() -> Bool)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
                guard let window = self?.window, event.window === window else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53, window.firstResponder is NSTextView {
                        if self?.onEscape?() != true { window.makeFirstResponder(nil) }
                        return nil
                    }
                    return event
                }
                var hit = window.contentView?.hitTest(event.locationInWindow)
                while let view = hit {
                    if view is NSTextField || (view as? NSTextView)?.isEditable == true { return event }
                    hit = view.superview
                }
                window.makeFirstResponder(nil)
                return event
            }
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}

struct FormSuggestionSelection {
    private(set) var isOpen = false
    private(set) var selectedIndex: Int?

    mutating func open() {
        isOpen = true
        selectedIndex = nil
    }

    mutating func close() {
        self = FormSuggestionSelection()
    }

    mutating func dismiss(matches: [String]) -> Bool {
        close()
        return !matches.isEmpty
    }

    func selected(in matches: [String]) -> String? {
        guard let selectedIndex, matches.indices.contains(selectedIndex) else { return nil }
        return matches[selectedIndex]
    }

    mutating func activate(matches: [String]) -> Bool {
        guard !matches.isEmpty else { return false }
        if selected(in: matches) == nil { selectedIndex = 0 }
        return true
    }

    mutating func handle(_ command: Selector, matches: [String]) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            guard !matches.isEmpty else { return false }
            selectedIndex = min((selectedIndex ?? -1) + 1, matches.count - 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard let selectedIndex, matches.indices.contains(selectedIndex) else { return false }
            self.selectedIndex = max(selectedIndex - 1, 0)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            return dismiss(matches: matches)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            close()
            return false
        default:
            return false
        }
    }
}

struct FormSuggestionFieldBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// An explicit keyboard target for a list entered from an AppKit field editor.
struct ListKeyboardFocus: NSViewRepresentable {
    @Binding var isFocused: Bool
    let onCommand: (Selector) -> Bool

    func makeNSView(context: Context) -> Target {
        let view = Target()
        view.focusRingType = .none
        return view
    }

    func updateNSView(_ view: Target, context: Context) {
        view.focused = $isFocused
        view.onCommand = onCommand
        guard isFocused, view.window?.firstResponder !== view else { return }
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.firstResponder !== view,
                  view.focused?.wrappedValue == true else { return }
            view.originatingField = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
            window.makeFirstResponder(view)
        }
    }

    final class Target: NSView {
        var focused: Binding<Bool>?
        var onCommand: ((Selector) -> Bool)?
        weak var originatingField: NSTextField?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            focused?.wrappedValue = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                super.keyDown(with: event)
                return
            }
            let command: Selector
            switch event.keyCode {
            case 125: command = #selector(NSResponder.moveDown(_:))
            case 126: command = #selector(NSResponder.moveUp(_:))
            case 36, 76: command = #selector(NSResponder.insertNewline(_:))
            case 53: command = #selector(NSResponder.cancelOperation(_:))
            case 48:
                command = event.modifierFlags.contains(.shift)
                    ? #selector(NSResponder.insertBacktab(_:)) : #selector(NSResponder.insertTab(_:))
            default: super.keyDown(with: event); return
            }
            if onCommand?(command) == true { return }
            guard command == #selector(NSResponder.insertTab(_:)) else {
                super.keyDown(with: event)
                return
            }
            if let originatingField, let window, originatingField.window === window {
                window.selectKeyView(following: originatingField)
            } else { window?.selectNextKeyView(self) }
        }
    }
}

struct FormSuggestionOverlay: View {
    let anchor: Anchor<CGRect>?
    let matches: [String]
    let selectedIndex: Int?
    let element: (String) -> InterfaceLayoutElement
    let choose: (String) -> Void
    var keyboardFocus: Binding<Bool>?
    var onListCommand: ((Selector) -> Bool)?

    var body: some View {
        GeometryReader { geometry in
            if let anchor, !matches.isEmpty {
                let field = geometry[anchor]
                let top = field.maxY + PisaDesign.Spacing.compact
                let availableHeight = geometry.size.height - top - 2 * PisaDesign.Spacing.compact
                if field.minY >= 0, availableHeight >= PisaDesign.Metrics.regularHeight {
                    list(maxContentHeight: availableHeight)
                        .frame(width: field.width)
                        .offset(x: field.minX, y: top)
                }
            }
        }
    }

    @ViewBuilder private func list(maxContentHeight: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)
        let list = ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.none) {
                    ForEach(Array(matches.enumerated()), id: \.element) { index, match in
                        FormSuggestionRow(text: match, selected: index == selectedIndex) { choose(match) }
                            .id(index)
                            .measuredForInterfaceTest(element(match))
                    }
                }
            }
            .frame(height: min(CGFloat(matches.count) * PisaDesign.Metrics.regularHeight,
                               PisaDesign.Metrics.editorHeight, maxContentHeight))
            .padding(PisaDesign.Spacing.compact)
            .background {
                shape.fill(Color.paper)
                    .shadow(color: Color.ink.opacity(0.12), radius: PisaDesign.Spacing.inline, y: PisaDesign.Spacing.hairline)
            }
            .overlay {
                shape.strokeBorder(PisaDesign.Colors.secondaryAction, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onChange(of: selectedIndex) { _, index in
                if let index { proxy.scrollTo(index) }
            }
        }
        .background(SlimScrollbars().allowsHitTesting(false))
        if let keyboardFocus, let onListCommand {
            list.background(ListKeyboardFocus(isFocused: keyboardFocus, onCommand: onListCommand))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(typographicText("Подсказки"))
        } else {
            list
        }
    }
}

private struct FormSuggestionRow: View {
    let text: String
    let selected: Bool
    let choose: () -> Void
    @State private var hovered = false

    private var fill: Color {
        if selected { return Color.moss.opacity(0.14) }
        return hovered ? PisaDesign.Colors.secondaryHover : .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)
        Button(action: choose) {
            screenText(text)
                .lineLimit(1)
                .padding(.horizontal, PisaDesign.Spacing.inline)
                .frame(maxWidth: .infinity, minHeight: PisaDesign.Metrics.regularHeight, alignment: .leading)
                .background(fill, in: shape)
                .contentShape(shape)
        }
        .shapeAwarePlainButton()
        .onHover { hovered = $0 }
        .screenHelp(text)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
