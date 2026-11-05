import SwiftUI
import AppKit

struct PisyaApp: App {
    @NSApplicationDelegateAdaptor(PisyaDelegate.self) private var delegate
    @StateObject private var state = AppState()
    var body: some Scene {
        Window("Pisya", id: "main") {
            MainView().environmentObject(state).frame(minWidth: 980, minHeight: 660)
                .background(MainWindowConnection(state: state, delegate: delegate).allowsHitTesting(false))
                .preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "ru_RU"))
                .alert(state.permissionIssue == nil ? "Pisya" : "Нужно разрешение macOS", isPresented: Binding(get: { state.message != nil || state.permissionIssue != nil }, set: { if !$0 { state.message = nil; state.permissionIssue = nil } })) {
                    if let permission = state.permissionIssue {
                        screenButton("Открыть настройки") { NSWorkspace.shared.open(permission.settingsURL) }
                        screenButton("Позже", role: .cancel) { }
                    } else {
                        screenButton("Понятно", role: .cancel) { }
                    }
                } message: { screenText(state.permissionIssue?.localizedDescription ?? state.message ?? "") }
                .sheet(isPresented: $state.showingSettings) { SettingsView().environmentObject(state) }
                .sheet(isPresented: Binding(get: { state.modelSetup.presented }, set: { state.modelSetup.presented = $0 })) {
                    ModelSetupView(setup: state.modelSetup, onReady: { state.modelInstallationCompleted() })
                }
                .focusEffectDisabled()
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                screenButton("О программе Pisya") {
                    var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
                    if let url = Bundle.main.url(forResource: "PisyaPlain", withExtension: "icns"),
                       let icon = NSImage(contentsOf: url) {
                        options[.applicationIcon] = icon
                    }
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center; paragraph.paragraphSpacing = PisyaDesign.Spacing.inline
                    let credits = "Максим Берёзкин\nmaxim@berezkin.ru\n" + typographicText("Сделано нами для нас") + "\u{00a0}💚"
                    let attributedCredits = NSMutableAttributedString(string: credits, attributes: [
                        .font: AppTypography.credits,
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                    ])
                    attributedCredits.addAttributes([
                        .link: URL(string: "mailto:maxim@berezkin.ru")!,
                        .foregroundColor: NSColor(Color.moss),
                        .underlineStyle: NSUnderlineStyle.single.rawValue
                    ], range: (credits as NSString).range(of: "maxim@berezkin.ru"))
                    options[.credits] = attributedCredits
                    NSApp.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(replacing: .newItem) { screenButton("Импортировать аудио…") { state.importAudio() }.keyboardShortcut("o") }
            CommandGroup(after: .windowList) {
                screenButton("На всю ширину") {
                    guard let window = NSApp.mainWindow, let screen = window.screen,
                          !window.styleMask.contains(.fullScreen) else { return }
                    var frame = window.frame
                    frame.origin.x = screen.visibleFrame.minX
                    frame.size.width = screen.visibleFrame.width
                    window.setFrame(frame, display: true, animate: true)
                }
                screenButton("Показать меню записи") { delegate.showStatusMenu() }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appSettings) { screenButton("Настройки…") { state.showingSettings = true }.keyboardShortcut(",") }
        }
    }
}
private struct MainWindowConnection: View {
    let state: AppState
    let delegate: PisyaDelegate
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear.onAppear { delegate.connect(state, openMain: { openWindow(id: "main") }); state.modelSetup.check() }
    }
}

struct RecordingElapsed: View {
    let started: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            screenText(recordingTimecode(clock.date.timeIntervalSince(started))).textStyle(PisyaDesign.Typography.elapsed)
        }.frame(width: PisyaDesign.Metrics.elapsedWidth, height: PisyaDesign.Metrics.elapsedHeight, alignment: .leading)
    }
}
@MainActor
final class PisyaDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var statusController: StatusBarController?
    func connect(_ state: AppState, openMain: @escaping () -> Void) {
        self.state = state
        if statusController == nil { statusController = StatusBarController(state: state, openMain: openMain) }
    }
    func showStatusMenu() { statusController?.showMenu() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "PisyaPlain", withExtension: "icns") {
            NSApp.applicationIconImage = NSImage(contentsOf: url)
        }
        DispatchQueue.main.async {
            // Start without highlighting a toolbar action; Tab still enables keyboard navigation.
            NSApp.windows.first(where: { $0.canBecomeMain })?.makeFirstResponder(nil)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state else { return .terminateNow }
        if state.recording || state.starting || state.processingID != nil {
            state.message = "Сначала завершите запись или остановите обработку, чтобы сохранить результат"
            sender.activate(ignoringOtherApps: true)
            sender.windows.first?.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        if state.modelSetup.busy {
            Task { @MainActor in
                await state.modelSetup.cancelAndWait()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
