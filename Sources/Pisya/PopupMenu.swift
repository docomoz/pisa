import AppKit
import SwiftUI

struct NativeActionMenu<Label: View>: View {
    var items: () -> [NSMenuItem]
    @ViewBuilder var label: () -> Label
    @State private var anchor = NSView()
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: open, label: label)
            .background(Anchor(view: anchor).allowsHitTesting(false).accessibilityHidden(true))
            .onKeyPress(keys: [.return, .downArrow]) { _ in
                guard enabled else { return .ignored }
                open()
                return .handled
            }
    }

    private func open() {
        guard anchor.window != nil else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.minimumWidth = anchor.bounds.width
        menu.items = items()
        let location = NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY - PisyaDesign.Spacing.compact)
        menu.popUp(positioning: nil, at: location, in: anchor)
    }

    private struct Anchor: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

final class NativeActionMenuItem: NSMenuItem {
    private let perform: () -> Void

    init(_ title: String, enabled: Bool = true, perform: @escaping () -> Void) {
        self.perform = perform
        super.init(title: typographicText(title), action: nil, keyEquivalent: "")
        target = self
        action = #selector(activate)
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { perform() }
}

struct PopupKeyboardNavigation: ViewModifier {
    @Binding var showsFocus: Bool
    var supportsArrowKeys = false
    var closeOnEscape: (() -> Void)? = nil
    @State private var id = UUID()
    @State private var monitor: Any?
    private static var activePopups: [UUID] = []

    static var openedWithKeyboard: Bool {
        let type = NSApp.currentEvent?.type
        return type == .keyDown || type == .keyUp
    }

    func body(content: Content) -> some View {
        content
            .environment(\.showsControlKeyboardFocus, showsFocus)
            .onAppear {
                guard monitor == nil else { return }
                Self.activePopups.append(id)
                // Observe Tab before AppKit moves focus, then let it perform normal traversal.
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) {
                    [id, focus = $showsFocus, supportsArrowKeys, closeOnEscape] event in
                    guard Self.activePopups.last == id else { return event }
                    guard event.type == .keyDown else {
                        focus.wrappedValue = false
                        return event
                    }
                    guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
                    if event.keyCode == 53, let closeOnEscape {
                        closeOnEscape()
                        return nil
                    }
                    if event.keyCode == 48 { focus.wrappedValue = true }
                    if supportsArrowKeys && [125, 126].contains(event.keyCode) {
                        focus.wrappedValue = true
                        return Self.traversalEvent(from: event)
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                Self.activePopups.removeAll { $0 == id }
            }
    }

    private static func traversalEvent(from event: NSEvent) -> NSEvent? {
        let backwards = event.keyCode == 126
        let character = backwards ? "\u{19}" : "\t"
        return NSEvent.keyEvent(with: .keyDown, location: event.locationInWindow,
            modifierFlags: backwards ? .shift : [], timestamp: event.timestamp,
            windowNumber: event.windowNumber, context: nil, characters: character,
            charactersIgnoringModifiers: character, isARepeat: event.isARepeat, keyCode: 48) ?? event
    }
}

struct PopupMenu<Items: View, Label: View>: View {
    var arrowEdge: Edge = .trailing
    @ViewBuilder var items: () -> Items
    @ViewBuilder var label: () -> Label
    @State private var isPresented = false
    @State private var showsFocus = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button {
            open(keyboard: PopupKeyboardNavigation.openedWithKeyboard)
        } label: {
            label()
        }
        .accessibilityValue(isPresented ? "Открыто" : "Закрыто")
        .onKeyPress(keys: [.return, .downArrow, .rightArrow]) { _ in
            guard enabled else { return .ignored }
            open(keyboard: true)
            return .handled
        }
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            PopupMenuSurface(showsFocus: $showsFocus, close: { isPresented = false }, items: items)
        }
    }

    private func open(keyboard: Bool) {
        showsFocus = keyboard
        isPresented.toggle()
    }
}

struct PopupMenuSurface<Items: View>: View {
    @Binding var showsFocus: Bool
    var close: () -> Void
    @ViewBuilder var items: () -> Items
    @Environment(\.closePopupMenus) private var closeParent

    var body: some View {
        ViewThatFits(in: .vertical) {
            rows.fixedSize(horizontal: false, vertical: true)
            ScrollView { rows }
        }
        .padding(PisyaDesign.Spacing.inline)
        .frame(idealWidth: 248, maxHeight: 360)
        .fixedSize(horizontal: true, vertical: false)
        .popupCanvas()
        .environment(\.closePopupMenus, { close(); closeParent?() })
        .modifier(PopupKeyboardNavigation(showsFocus: $showsFocus, supportsArrowKeys: true,
                                          closeOnEscape: close))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.hairline, content: items)
    }
}

private struct ClosePopupMenusKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

private extension EnvironmentValues {
    var closePopupMenus: (() -> Void)? {
        get { self[ClosePopupMenusKey.self] }
        set { self[ClosePopupMenusKey.self] = newValue }
    }
}

struct PopupMenuItem: View {
    let title: String
    var systemImage: String? = nil
    var role: ButtonRole? = nil
    var closesOnAction = true
    let action: () -> Void
    @Environment(\.closePopupMenus) private var close
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, systemImage: String? = nil, role: ButtonRole? = nil,
         closesOnAction: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.closesOnAction = closesOnAction
        self.action = action
    }

    var body: some View {
        Button(role: role, action: activate) {
            if let systemImage {
                screenLabel(title, systemImage: systemImage)
            } else {
                screenText(title)
            }
        }
        .popupMenuRow()
        .onKeyPress(.return) {
            guard enabled else { return .ignored }
            activate()
            return .handled
        }
    }

    private func activate() {
        if closesOnAction { close?() }
        action()
    }
}

extension View {
    func popupMenuRow() -> some View {
        buttonStyle(PopupMenuRowStyle()).controlKeyboardFocus()
    }
}

private struct PopupMenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(label: configuration.label, pressed: configuration.isPressed, destructive: configuration.role == .destructive)
    }

    private struct Row: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        let destructive: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlFocused) private var focused
        @State private var hovered = false

        private var fill: Color {
            guard enabled else { return .clear }
            if pressed || focused { return PisyaDesign.Colors.secondaryPressed }
            return hovered ? PisyaDesign.Colors.secondaryHover : .clear
        }

        var body: some View {
            label.textStyle(PisyaDesign.Typography.detail)
                .foregroundStyle(enabled ? (destructive ? Color.recordingRed : Color.ink) : Color.disabledInk)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PisyaDesign.Spacing.inline)
                .frame(maxWidth: .infinity, minHeight: PisyaDesign.Metrics.smallHeight, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

extension View {
    func popupContextMenu<Items: View>(onOpen: @escaping () -> Void = {}, @ViewBuilder items: @escaping () -> Items) -> some View {
        modifier(PopupContextMenu(onOpen: onOpen, items: items))
    }
}

private struct PopupContextMenu<Items: View>: ViewModifier {
    let onOpen: () -> Void
    @ViewBuilder var items: () -> Items
    @State private var isPresented = false
    @State private var anchor = UnitPoint.bottomLeading
    @State private var showsFocus = false

    func body(content: Content) -> some View {
        content
            .background(SecondaryClickObserver { point in open(at: point, keyboard: false) }.allowsHitTesting(false))
            .accessibilityAction(named: Text("Показать действия")) { open(at: .bottomLeading, keyboard: true) }
            .popover(isPresented: $isPresented, attachmentAnchor: .point(anchor), arrowEdge: .leading) {
                PopupMenuSurface(showsFocus: $showsFocus, close: { isPresented = false }, items: items)
            }
    }

    private func open(at point: UnitPoint, keyboard: Bool) {
        onOpen()
        anchor = point
        showsFocus = keyboard
        isPresented = true
    }
}

private struct SecondaryClickObserver: NSViewRepresentable {
    var action: (UnitPoint) -> Void

    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) { view.action = action }

    final class ClickView: NSView {
        var action: (UnitPoint) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                guard let self, event.window === self.window,
                      event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)),
                      bounds.width > 0, bounds.height > 0 else { return event }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.intersection(visibleRect).contains(point) else { return event }
                let x = (point.x - bounds.minX) / bounds.width
                let y = (point.y - bounds.minY) / bounds.height
                action(UnitPoint(x: x, y: isFlipped ? y : 1 - y))
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
