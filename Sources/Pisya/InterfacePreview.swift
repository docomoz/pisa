import AppKit
import SwiftUI

/// Opens the production views with disposable content. Never opens the user's library.
@MainActor
final class InterfacePreview: NSObject {
    private let state: AppState
    private let meeting: Meeting
    private let window: NSWindow

    private init(root: URL) throws {
        state = AppState(rootURL: root)
        try VoiceProfileTests.seed(state, count: 12)
        state.modelSetup.phase = .ready
        var fixture = Meeting(title: "Обсуждение планов и результатов проверки интерфейса", source: "Тестовое аудио")
        fixture.status = .ready
        if CommandLine.arguments.contains("--processing-preview") { fixture.status = .processing }
        fixture.duration = 180
        if let example = state.voiceProfiles.first?.examples?.first {
            let file = "preview-mic.caf"
            try FileManager.default.copyItem(at: root.appendingPathComponent("VoiceSamples").appendingPathComponent(example.file), to: state.library.audioURL(file))
            fixture.audioFiles = [file]
        }
        fixture.segments = (0..<20).map { index in
            var segment = TranscriptSegment(start: Double(index * 8), end: Double(index * 8 + 3), speaker: index.isMultiple(of: 2) ? "Анна" : "Борис", text: "На следующей встрече обсудим планы команды и результаты проверки. Посмотрим, как читается длинный текст, где переносятся строки и достаточно ли расстояния между ними. После обсуждения сохраним решения и вернёмся к открытым вопросам.")
            segment.embedding = index.isMultiple(of: 2) ? [1, 0] : [0, 1]
            return segment
        }
        meeting = fixture
        state.update(fixture)
        state.select(fixture.id)
        if CommandLine.arguments.contains("--processing-preview") {
            state.processingID = fixture.id
            state.liveStatus = "Завершаю расшифровку"
        }
        if CommandLine.arguments.contains("--queue-preview") {
            state.processingID = UUID()
            state.enqueue(fixture.id, reprocess: true)
        }
        state.preferences.vocabulary = Array(repeating: "2ГИС, Бронегис, Геопэй, названия проектов для проверки длинного словаря", count: 18).joined(separator: "\n")
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Pisya · Проверка интерфейса"
        window.minSize = NSSize(width: 980, height: 660)
        let hosting = NSHostingView(rootView: InterfacePreviewRoot(state: state, setup: state.modelSetup)
            .preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU")))
        // The review window owns its size, as SwiftUI's Window does in the app.
        // Content switches must not resize it to a view's unconstrained ideal size.
        hosting.sizingOptions = []
        window.contentView = hosting
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Pisya", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Завершить просмотр", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let reviewItem = NSMenuItem(title: "Просмотр", action: nil, keyEquivalent: "")
        let reviewMenu = NSMenu()
        for (index, title) in ["Главный экран", "Расшифровка", "Настройки", "Пустой список голосов", "Список голосов", "Первая настройка", "Модели готовы", "Проверка моделей", "Загрузка моделей", "Ошибка загрузки", "Окно 1200 × 800", "Окно 980 × 660"].enumerated() {
            let item = reviewMenu.addItem(withTitle: title, action: #selector(show(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
        }
        reviewItem.submenu = reviewMenu
        menu.addItem(reviewItem)
        NSApp.mainMenu = menu
    }

    @objc private func show(_ sender: NSMenuItem) {
        switch sender.tag {
        case 0: state.select(nil)
        case 1: state.select(meeting.id)
        case 2: state.showingSettings = true
        case 3: state.voiceProfiles = []; state.showingSettings = true
        case 4:
            state.voiceProfiles = (try? state.library.voices()) ?? []
            state.showingSettings = true
        case 10, 11:
            window.setContentSize(sender.tag == 10 ? NSSize(width: 1200, height: 800) : NSSize(width: 980, height: 660))
            window.center()
        default:
            let setup = state.modelSetup
            setup.phase = sender.tag == 6 ? .ready : sender.tag == 7 ? .checking : sender.tag == 8 ? .downloading : sender.tag == 9 ? .failed : .available
            setup.error = sender.tag == 9 ? "Не удалось загрузить модель. Проверьте подключение к интернету и повторите попытку. Уже загруженные файлы сохранены." : nil
            setup.presented = true
        }
    }

    static func testQueue() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Queue-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        state.modelSetup.phase = .ready
        let active = UUID()
        let first = Meeting(title: "Первая", source: "Аудио")
        let second = Meeting(title: "Вторая", source: "Аудио")
        state.update(first); state.update(second); state.processingID = active
        state.enqueue(first.id, reprocess: true); state.enqueue(second.id)
        guard state.isQueued(first.id), state.isQueued(second.id) else { throw PisyaError.message("Записи не добавлены в очередь") }
        state.rename(first, to: "Название в очереди")
        guard try state.library.read(first.id).title == "Название в очереди" else { throw PisyaError.message("Не удалось переименовать запись в очереди") }
        var processing = Meeting(title: "Исходное название", source: "Аудио")
        processing.status = .processing
        processing.segments = [.init(start: 0, end: 1, speaker: "Я", text: "Привет")]
        state.update(processing); state.processingID = processing.id
        state.rename(processing, to: "Название во время расшифровки")
        var completed = try state.library.read(processing.id)
        guard completed.title == "Название во время расшифровки", completed.segments == processing.segments else { throw PisyaError.message("Переименование во время расшифровки не сохранилось или изменило текст") }
        completed.status = .ready
        _ = completed.applyGeneratedTitle("Автоматическое название")
        try state.library.save(completed)
        guard try state.library.read(processing.id).title == "Название во время расшифровки" else { throw PisyaError.message("Название изменилось после завершения расшифровки") }
        state.processingID = active
        state.cancelQueued(first.id)
        guard !state.isQueued(first.id), state.isQueued(second.id), state.processingID == active,
              try state.library.read(first.id).title == "Название в очереди" else { throw PisyaError.message("Отмена изменила запись или другую задачу") }
        state.enqueue(first.id)
        guard state.isQueued(first.id) else { throw PisyaError.message("Запись нельзя снова добавить в очередь") }
        state.cancelQueued(first.id); state.cancelQueued(second.id); state.cancelQueued(active)
        guard state.processingID == active else { throw PisyaError.message("Отмена очереди остановила обработку") }
    }

    static func run() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Interface-Preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = try InterfacePreview(root: root)
        preview.window.center(); preview.window.makeKeyAndOrderFront(nil)
        preview.window.makeFirstResponder(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(preview) { app.run() }
    }
}

private struct InterfacePreviewRoot: View {
    @ObservedObject var state: AppState
    @ObservedObject var setup: ModelSetup
    var body: some View {
        MainView().environmentObject(state)
            .sheet(isPresented: $state.showingSettings) { SettingsView().environmentObject(state) }
            .sheet(isPresented: $setup.presented) { ModelSetupView(setup: setup, onReady: {}) }
    }
}
