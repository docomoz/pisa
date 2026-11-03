import AppKit
import SwiftUI
import Combine

/// Native title measurement avoids SwiftUI MenuBarExtra's recursive layout of a clock.
@MainActor
final class StatusBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let state: AppState
    private let openMain: () -> Void
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    init(state: AppState, openMain: @escaping () -> Void) {
        self.state = state; self.openMain = openMain
        super.init()
        if let button = item.button {
            button.image = BrandMark.menuIcon
            button.imagePosition = .imageLeading
            button.font = AppTypography.counterFont(size: 12)
            button.target = self; button.action = #selector(togglePopover)
        }
        let content = MenuContents(showMain: { [weak self] in self?.showMainWindow() })
            .environmentObject(state).preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU"))
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = false
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
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    func showPopover() {
        guard let button = item.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.async { [weak self] in self?.popover.contentViewController?.view.window?.makeFirstResponder(nil) }
    }
    private func showMainWindow() {
        popover.performClose(nil); openMain(); NSApp.activate(ignoringOtherApps: true)
    }
    deinit { timer?.invalidate() }
}
