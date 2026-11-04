import AppKit
import Combine

/// Native title measurement avoids SwiftUI MenuBarExtra's recursive layout of a clock.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let recordAction = NSMenuItem(title: "Начать запись", action: #selector(toggleRecording), keyEquivalent: "")
    private let automaticAction = NSMenuItem(title: "Автоматическая запись", action: #selector(toggleAutomatic), keyEquivalent: "")
    private let automaticControl = PersistentMenuToggle(title: "Автоматическая запись")
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
            button.font = AppTypography.statusCounter
        }
        // Let AppKit draw the same compact, translucent menu used by other menu-bar apps.
        menu.delegate = self
        menu.autoenablesItems = false
        // The checkbox is a control inside the row, rather than a native menu state.
        // Keeping menu states empty prevents the title column from shifting.
        menu.showsStateColumn = false
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
    }
    func menuWillOpen(_ menu: NSMenu) {
        automaticControl.menuHighlighted = false
        updateMenu()
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.menu.highlightedItem === self.automaticAction,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  [36, 49, 76].contains(event.keyCode) else { return event }
            self.toggleAutomatic()
            return nil
        }
    }
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        automaticControl.menuHighlighted = item === automaticAction
    }
    func menuDidClose(_ menu: NSMenu) {
        automaticControl.menuHighlighted = false
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
    }

    private func updateMenu() {
        recordAction.title = state.starting
            ? (state.recordingStarted == nil ? "Подготовка…" : "Сохраняю…")
            : (state.recording ? "Остановить запись" : "Начать запись")
        recordAction.isEnabled = !state.starting && !state.demo
        automaticControl.state = state.preferences.automaticRecording ? .on : .off
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

/// A persistent checkbox row whose indicator remains legible on the menu selection.
@MainActor
private final class PersistentMenuToggle: NSButton {
    private let label: NSTextField
    private let checkbox = MenuCheckboxIndicator()
    var menuHighlighted = false {
        didSet { if oldValue != menuHighlighted { needsDisplay = true } }
    }

    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }

    init(title: String) {
        let font = AppTypography.menu
        label = NSTextField(labelWithString: title)
        label.font = font
        let width = label.fittingSize.width + PisyaDesign.Spacing.content
            + PisyaDesign.Spacing.content * 2 + PisyaDesign.Spacing.related
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(width), height: PisyaDesign.Spacing.section))
        self.title = title
        self.font = font
        setButtonType(.pushOnPushOff)
        isBordered = false
        focusRingType = .none
        autoresizingMask = [.width]
        setAccessibilityRole(.checkBox)
        checkbox.imageScaling = .scaleProportionallyUpOrDown
        checkbox.image = NSImage(systemSymbolName: "square", accessibilityDescription: nil)
        checkbox.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        for view in [label, checkbox] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PisyaDesign.Spacing.content),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PisyaDesign.Spacing.content),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: PisyaDesign.Spacing.content),
            checkbox.heightAnchor.constraint(equalToConstant: PisyaDesign.Spacing.content),
            label.trailingAnchor.constraint(lessThanOrEqualTo: checkbox.leadingAnchor, constant: -PisyaDesign.Spacing.related)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        // The delegate supplies the incoming item before AppKit updates highlightedItem.
        // A retained button focus must never reselect this row when the pointer leaves it.
        let selected = menuHighlighted
        if selected {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: PisyaDesign.Spacing.inline / 2, dy: 0), xRadius: PisyaDesign.Spacing.inline / 2, yRadius: PisyaDesign.Spacing.inline / 2).fill()
        }
        label.textColor = selected ? .selectedMenuItemTextColor : .labelColor
        let colors: [NSColor] = state == .on
            ? (selected ? [.selectedContentBackgroundColor, .white] : [.white, .selectedContentBackgroundColor])
            : [selected ? .white : .secondaryLabelColor]
        let symbol = NSImage(systemSymbolName: state == .on ? "checkmark.square.fill" : "square", accessibilityDescription: nil)
        let palette = colors.map { $0.usingColorSpace(.sRGB) ?? $0 }
        let image = symbol?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: palette))?.copy() as? NSImage
        image?.isTemplate = false
        checkbox.image = image
    }
}

/// Preserve the indicator's explicit palette instead of applying menu vibrancy.
private final class MenuCheckboxIndicator: NSImageView {
    override var allowsVibrancy: Bool { false }
}
