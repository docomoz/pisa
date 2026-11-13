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
            .onKeyPress(keys: [.return, .downArrow, .rightArrow]) { _ in
                guard enabled else { return .ignored }
                open()
                return .handled
            }
    }

    private func open() {
        guard anchor.window != nil else { return }
        let menu = nativeActionMenu(items: items(), minimumWidth: anchor.bounds.width)
        let location = NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY - PisaDesign.Spacing.compact)
        menu.popUp(positioning: nil, at: location, in: anchor)
        restorePointingCursor(over: anchor)
    }

    private struct Anchor: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}

private func restorePointingCursor(over view: NSView) {
    guard NSApp.isActive, let window = view.window else { return }
    let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    if view.bounds.intersection(view.visibleRect).contains(point) { NSCursor.pointingHand.set() }
}

func nativeActionMenu(items: [NSMenuItem], minimumWidth: CGFloat = 0) -> NSMenu {
    let menu = PointingActionMenu()
    menu.autoenablesItems = false
    menu.showsStateColumn = false
    menu.minimumWidth = minimumWidth
    menu.items = items
    return menu
}

private final class PointingActionMenu: NSMenu, NSMenuDelegate {
    init() {
        super.init(title: "")
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        // Keyboard selection must not change the cursor under a stationary mouse.
        if NSApp.currentEvent?.type == .keyDown { return }
        if let item, item.isEnabled, !item.isSeparatorItem {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if NSCursor.current == NSCursor.pointingHand { NSCursor.arrow.set() }
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

extension View {
    func popupContextMenu(onOpen: @escaping () -> Void = {}, items: @escaping () -> [NSMenuItem]) -> some View {
        modifier(NativeContextMenu(onOpen: onOpen, items: items))
    }
}

private struct NativeContextMenu: ViewModifier {
    let onOpen: () -> Void
    let items: () -> [NSMenuItem]
    @State private var anchor = SecondaryClickObserver.ClickView()

    func body(content: Content) -> some View {
        content
            .background(SecondaryClickObserver(view: anchor, onOpen: onOpen, items: items)
                .allowsHitTesting(false).accessibilityHidden(true))
            .accessibilityAction(named: Text("Показать действия")) {
                anchor.open(at: NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY))
            }
    }
}

private struct SecondaryClickObserver: NSViewRepresentable {
    let view: ClickView
    var onOpen: () -> Void
    var items: () -> [NSMenuItem]

    func makeNSView(context: Context) -> ClickView { view }
    func updateNSView(_ view: ClickView, context: Context) {
        view.onOpen = onOpen
        view.items = items
    }

    final class ClickView: NSView {
        var onOpen: () -> Void = {}
        var items: () -> [NSMenuItem] = { [] }
        private var monitor: Any?

        func open(at point: NSPoint) {
            guard window != nil else { return }
            onOpen()
            nativeActionMenu(items: items()).popUp(positioning: nil, at: point, in: self)
            restorePointingCursor(over: self)
        }

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
                open(at: point)
                return nil
            }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
