import AppKit
import Combine

/// Native title measurement avoids SwiftUI MenuBarExtra's recursive layout of a clock.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let recordingStatus = NSMenuItem(title: "Идёт запись", action: nil, keyEquivalent: "")
    private let recordAction = NSMenuItem(title: "Начать запись", action: #selector(toggleRecording), keyEquivalent: "")
    private let automaticAction = NSMenuItem(title: "Автоматический старт и стоп", action: #selector(toggleAutomatic), keyEquivalent: "")
    private let automaticControl = PersistentMenuToggle(title: "Автоматический старт и стоп")
    private let state: AppState
    private let openMain: () -> Void
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var keyboardMonitor: Any?
    init(state: AppState, openMain: @escaping () -> Void) {
        self.state = state; self.openMain = openMain
        super.init()
        if let button = item.button {
            button.image = BrandMark.menuIcon
            button.imagePosition = .imageLeading
            button.font = AppTypography.counterFont(size: 12)
        }
        // Let AppKit draw the same compact, translucent menu used by other menu-bar apps.
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(recordingStatus)
        menu.addItem(withTitle: "Открыть Pisya", action: #selector(showMainWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(recordAction)
        menu.addItem(automaticAction)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Завершить Pisya", action: #selector(quit), keyEquivalent: "q")
        for entry in menu.items { entry.target = self }
        // A control inside a menu handles its click without ending menu tracking.
        automaticControl.target = self
        automaticControl.action = #selector(toggleAutomatic)
        automaticAction.view = automaticControl
        item.menu = menu
        updateMenu()
        state.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateMenu() }.store(in: &subscriptions)
        state.$recording.combineLatest(state.$recordingStarted).receive(on: RunLoop.main).sink { [weak self] _ in self?.updateCounter() }.store(in: &subscriptions)
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateCounter() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        updateCounter()
    }
    private func updateCounter() {
        guard let button = item.button else { return }
        let text: String
        if state.recording, let started = state.recordingStarted { text = recordingTimecode(Date().timeIntervalSince(started)) }
        else { text = "" }
        if button.title != text { button.title = text }
        // Native AppKit measures a plain string once per second; no hosted clock view.
        button.setAccessibilityLabel(text.isEmpty ? "Pisya" : "Pisya · идёт запись · \(text)")
        button.toolTip = text.isEmpty ? "Pisya" : "Идёт запись · \(text)"
        recordingStatus.title = text.isEmpty ? "Идёт запись" : "Идёт запись · \(text)"
    }
    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.menu.highlightedItem === self.automaticAction,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  [36, 49, 76].contains(event.keyCode) else { return event }
            self.toggleAutomatic()
            return nil
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
    }

    private func updateMenu() {
        recordingStatus.isHidden = !state.recording
        recordingStatus.isEnabled = false
        recordAction.title = state.starting
            ? (state.recordingStarted == nil ? "Подготовка…" : "Сохраняю…")
            : (state.recording ? "Остановить запись" : "Начать запись")
        recordAction.isEnabled = !state.starting && !state.demo
        automaticAction.state = state.preferences.automaticRecording ? .on : .off
        automaticControl.state = automaticAction.state
        automaticControl.needsDisplay = true
    }
    func showMenu() { item.button?.performClick(nil) }

    @objc private func toggleRecording() {
        Task { if state.recording { await state.stopRecording(manual: true) } else { await state.startRecording() } }
    }
    @objc private func toggleAutomatic() {
        state.setAutomatic(!state.preferences.automaticRecording)
        updateMenu()
    }
    @objc private func quit() {
        if state.recording || state.starting || state.processingID != nil {
            state.message = "Сначала остановите запись или обработку"
            showMainWindow()
        } else { NSApp.terminate(nil) }
    }
    @objc private func showMainWindow() {
        openMain(); NSApp.activate(ignoringOtherApps: true)
    }
    deinit {
        timer?.invalidate()
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
}

/// Keeps the system menu's material while allowing repeated checkbox clicks.
@MainActor
private final class PersistentMenuToggle: NSButton {
    private var hovered = false

    init(title: String) {
        let font = NSFont.menuFont(ofSize: 0)
        let width = (title as NSString).size(withAttributes: [.font: font]).width
            + PisyaDesign.Spacing.section + PisyaDesign.Spacing.content
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: PisyaDesign.Spacing.section))
        self.title = title
        self.font = font
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        autoresizingMask = [.width]
        setAccessibilityRole(.checkBox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let selected = hovered || isHighlighted || enclosingMenuItem?.isHighlighted == true || window?.firstResponder === self
        if selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: PisyaDesign.Spacing.inline / 2, dy: 0), xRadius: PisyaDesign.Spacing.inline / 2, yRadius: PisyaDesign.Spacing.inline / 2).fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.menuFont(ofSize: 0),
            .foregroundColor: selected ? NSColor.selectedMenuItemTextColor : NSColor.labelColor
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        let y = (bounds.height - height) / 2
        (title as NSString).draw(at: NSPoint(x: PisyaDesign.Spacing.section, y: y), withAttributes: attributes)
        if state == .on {
            ("✓" as NSString).draw(at: NSPoint(x: PisyaDesign.Spacing.inline, y: y), withAttributes: attributes)
        }
    }
}
