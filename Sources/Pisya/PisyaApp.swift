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
        }
        .defaultSize(width: 1200, height: 800)
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
                    paragraph.alignment = .center; paragraph.paragraphSpacing = 8
                    let credits = typographicText("Автор: Максим Берёзкин · maxim@berezkin.ru") + "\n" + typographicText("Сделано нами для нас") + "\u{00a0}💚"
                    options[.credits] = NSAttributedString(string: credits, attributes: [
                        .font: NSFont.systemFont(ofSize: 14),
                        .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph
                    ])
                    NSApp.orderFrontStandardAboutPanel(options: options)
                }
            }
            CommandGroup(replacing: .newItem) { screenButton("Импортировать аудио…") { state.importAudio() }.keyboardShortcut("o") }
            CommandGroup(after: .windowList) {
                screenButton("Показать мини-панель записи") { delegate.showStatusPanel() }.keyboardShortcut("r", modifiers: [.command, .shift])
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
        Color.clear.onAppear { delegate.connect(state, openMain: { openWindow(id: "main") }) }
    }
}

struct RecordingElapsed: View {
    let started: Date
    var size: CGFloat = 13
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { clock in
            screenText(recordingTimecode(clock.date.timeIntervalSince(started))).font(.system(size: size, design: .monospaced))
        }.frame(width: size <= 11 ? 58 : 72, height: size <= 11 ? 15 : 20, alignment: .leading)
    }
}
struct MenuContents: View {
    @EnvironmentObject var state: AppState
    let showMain: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if state.recording {
                HStack {
                    screenText("Идёт запись").font(.appFont(size: 14, weight: .semibold))
                    Spacer()
                    if let started = state.recordingStarted { RecordingElapsed(started: started) }
                }
            }
            screenButton("Открыть Pisya") { showMain() }
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Button {
                Task { if state.recording { await state.stopRecording(manual: true) } else { await state.startRecording() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: state.recording ? "stop.circle" : "record.circle").frame(width: 16, height: 16)
                    screenText(state.starting ? "Подготовка…" : state.recording ? "Остановить запись" : "Записать встречу")
                }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.disabled(state.starting).foregroundStyle(Color.ink)
            screenToggle("Автоматический старт и стоп", isOn: Binding(get: { state.preferences.automaticRecording }, set: { state.setAutomatic($0) })).toggleStyle(MenuCheckboxStyle())
            Divider()
            screenButton("Завершить Pisya") {
                if state.recording || state.processingID != nil { state.message = "Сначала остановите запись или обработку"; showMain() }
                else { NSApp.terminate(nil) }
            }
        }.font(.appFont(size: 13)).buttonStyle(.plain).padding(16).frame(width: 300).popupCanvas()
    }
}

private struct MenuCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(configuration.isOn ? Color.moss : Color.ink)
                    .frame(width: 16, height: 16)
                configuration.label
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "Включено" : "Выключено")
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
    func showStatusPanel() { statusController?.showPopover() }
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
        return .terminateNow
    }
}
