import AppKit
import SwiftUI

@MainActor
enum VocabularyDictionaryPreview {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Dictionary-Preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        state.demo = true
        state.preferences.vocabulary = (CommandLine.arguments.contains("--empty-dictionary-preview") || Bundle.main.object(forInfoDictionaryKey: "PisyaEmptyDictionaryPreview") as? Bool == true) ? "" :
            "2ГИС, Яндекс; LinkedIn Premium\r\nЁлка\n" + (1...55).map {
                $0 == 28 ? "Очень длинное название исследовательского проекта по развитию картографических сервисов и городской навигации для проверки переноса строк" : "Проект \($0)"
            }.joined(separator: "\n")
        let menu = NSMenu()
        let appItem = NSMenuItem(title: "Pisya", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Завершить просмотр", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Скопировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem); app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pisya · Словарь"
        let hosting = NSHostingView(rootView: SettingsView(initialSection: "Словарь").environmentObject(state)
            .preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.appTextScale, (CommandLine.arguments.contains("--large-text-preview") || Bundle.main.object(forInfoDictionaryKey: "PisyaDictionaryLargeText") as? Bool == true) ? 1.2 : 1))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        app.run()
    }

    static func test() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Dictionary-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func check(_ value: Bool, _ message: String) throws {
            if !value { throw PisyaError.message(message) }
        }
        let state = AppState(rootURL: root)
        let original = " 2ГИС, Ёлка;Старое\r\nДубль,Дубль "
        try state.saveVocabulary(original)
        try check(try state.library.preferences().vocabulary == original, "Exact spelling/separators did not persist")
        let restarted = AppState(rootURL: root)
        try check(restarted.preferences.vocabulary == original, "Restart lost dictionary")
        let selected = VocabularyDictionary.entries(in: original)[1]
        try state.saveVocabulary(VocabularyDictionary.preview("Новое", vocabulary: state.preferences.vocabulary).vocabulary)
        try state.saveVocabulary(VocabularyDictionary.replacing(selected, with: "Ёлочка", in: state.preferences.vocabulary))
        try check(state.preferences.vocabulary.contains("Ёлочка") && state.preferences.vocabulary.hasSuffix("Новое"), "Edit lost concurrent append")
        let removed = try VocabularyDictionary.removing(VocabularyDictionary.entries(in: state.preferences.vocabulary)[0], from: state.preferences.vocabulary)
        try state.saveVocabulary(removed.vocabulary)
        try state.saveVocabulary(VocabularyDictionary.preview("Ещё", vocabulary: state.preferences.vocabulary).vocabulary)
        try state.saveVocabulary(removed.restoring(in: state.preferences.vocabulary))
        try check(state.preferences.vocabulary.hasPrefix(" 2ГИС,") && state.preferences.vocabulary.hasSuffix("Ещё"), "Undo lost position or subsequent append")
        let beforeFailure = state.preferences.vocabulary
        let preferencesURL = root.appendingPathComponent("preferences.json")
        try FileManager.default.removeItem(at: preferencesURL)
        try FileManager.default.createDirectory(at: preferencesURL, withIntermediateDirectories: true)
        var failed = false
        do { try state.saveVocabulary("Не должно сохраниться") } catch { failed = true }
        try check(failed && state.preferences.vocabulary == beforeFailure, "Failed write changed published memory")
        state.demo = true
        try state.saveVocabulary("Демонстрация")
        try check(state.preferences.vocabulary == "Демонстрация" && FileManager.default.fileExists(atPath: preferencesURL.path), "Demo should change memory only")
    }
}
