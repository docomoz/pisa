import SwiftUI
import AppKit

struct PisyaApp: App {
    @NSApplicationDelegateAdaptor(PisyaDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @AppStorage("appTextSize") private var textSize = AppTextSize.normal
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
                .sheet(item: $state.sourceNotice) { notice in
                    SourceNoticeView(message: notice.message)
                }
                .sheet(isPresented: $state.showingSettings) { SettingsView().environmentObject(state) }
                .sheet(isPresented: Binding(get: { state.modelSetup.presented }, set: { state.modelSetup.presented = $0 })) {
                    ModelSetupView(setup: state.modelSetup, onReady: { state.modelInstallationCompleted() })
                }
                .environment(\.appTextScale, AppTextSize.factor(for: textSize))
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
            CommandGroup(after: .toolbar) {
                screenButton("Увеличить текст") { changeTextSize(by: AppTextSize.step) }.keyboardShortcut("+")
                    .disabled(textSize >= AppTextSize.limits.upperBound)
                screenButton("Уменьшить текст") { changeTextSize(by: -AppTextSize.step) }.keyboardShortcut("-")
                    .disabled(textSize <= AppTextSize.limits.lowerBound)
                screenButton("Обычный размер текста") { textSize = AppTextSize.normal }.keyboardShortcut("0")
                    .disabled(textSize == AppTextSize.normal)
            }
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
            CommandGroup(replacing: .appSettings) { screenButton("Настройки") { state.showingSettings = true }.keyboardShortcut(",") }
        }
    }

    private func changeTextSize(by step: Int) {
        textSize = AppTextSize.clamp(AppTextSize.clamp(textSize) + step)
    }
}
struct SourceNoticeView: View {
    let message: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var buttonFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Ссылка на фрагмент", subtitle: message, style: .dialog)
            HStack(spacing: PisyaDesign.Spacing.related) {
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton("Понятно") { dismiss() }
                    .actionButton(.primary).focused($buttonFocused)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .dialogContent().frame(width: 480)
        .defaultFocus($buttonFocused, true)
        .onExitCommand { dismiss() }
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
    @Environment(\.appTextScale) private var textScale
    let started: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            screenText(recordingTimecode(clock.date.timeIntervalSince(started))).textStyle(PisyaDesign.Typography.elapsed)
        }.frame(
            width: PisyaDesign.Metrics.elapsedWidth * max(1, textScale),
            height: PisyaDesign.Metrics.elapsedHeight * max(1, textScale),
            alignment: .leading
        )
    }
}
@MainActor
final class PisyaDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    private var statusController: StatusBarController?
    private var openMain: (() -> Void)?
    private var pendingURLs: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs.append(contentsOf: urls)
        deliverURLs()
    }
    private func deliverURLs() {
        guard let state, let openMain else { return }
        guard !pendingURLs.isEmpty else { return }
        openMain()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil)
        let urls = pendingURLs; pendingURLs.removeAll()
        for url in urls { state.openSource(url) }
    }
    func connect(_ state: AppState, openMain: @escaping () -> Void) {
        self.state = state
        self.openMain = openMain
        deliverURLs()
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
