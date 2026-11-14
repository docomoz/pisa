import AppKit
import SwiftUI
import MLX

@MainActor
enum MeetingTitleTests {
    private static func argument(_ flag: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }
    static func smoke() async throws {
        guard let path = argument("--title-model-directory") else { throw PisaError.message("Provide the local title model directory") }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        let model = MeetingTitleModel()
        let texts = [
            "Сегодня обсуждаем запуск нового поиска в приложении. Исправили ошибки поиска организаций и подсказок. Анна завершит тесты, Борис проверит аналитику. Договорились выпустить новый поиск в декабре.",
            "We reviewed the marketing budget for next quarter. The advertising budget will increase by twenty percent. We agreed to spend more on search ads and reduce spending on social media campaigns.",
            Array(repeating: "Обсуждаем запуск нового поиска. Нужно исправить ошибки поиска организаций, проверить качество подсказок и метрики. Перед запуском поиска проверим поиск по адресу и названию, соберём обратную связь от пользователей.", count: 40).joined(separator: " ") + " Решили перенести запуск поиска на декабрь."
        ]
        for (index, text) in texts.enumerated() {
            let segment = TranscriptSegment(start: 0, end: 60, speaker: index == 1 ? "Alice" : "Анна", text: text)
            let title = try await model.title(for: [segment], root: root) { _ in }
            guard let title, title.localizedCaseInsensitiveContains(index == 1 ? "budget" : "поиск") else {
                throw PisaError.message("Missing expected topic in title: \(title ?? "nil")")
            }
            print("TITLE_MODEL_SAMPLE", index, title)
        }
        let previousCacheLimit = Memory.cacheLimit
        let cancellation = TitleCancellationTrigger()
        let cancelled = Task {
            try await model.title(for: [.init(start: 0, end: 60, speaker: "Анна", text: texts[2])], root: root) { phase in
                if phase == "Кратко пересказываю встречу" { await cancellation.schedule() }
            }
        }
        await cancellation.track(cancelled)
        do { _ = try await cancelled.value; throw PisaError.message("Title generation ignored cancellation") }
        catch is CancellationError {}
        guard Memory.cacheLimit == previousCacheLimit else { throw PisaError.message("Title cancellation did not restore memory policy") }
        let resumed = try await model.title(for: [.init(start: 0, end: 60, speaker: "Анна", text: texts[0])], root: root) { _ in }
        guard resumed?.localizedCaseInsensitiveContains("поиск") == true else { throw PisaError.message("Title model did not recover after cancellation") }
        print("TITLE_INFERENCE_SMOKE_OK russian english long_transcript cancellation recovery memory_policy")
    }
    private static func linkModel(from directory: URL, into root: URL) throws {
        let modelRoot = root.appendingPathComponent("Models").appendingPathComponent(MeetingTitleModel.directoryName)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        for name in ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"] {
            let target = modelRoot.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.linkItem(at: directory.appendingPathComponent(name), to: target)
            }
        }
    }

    static func run() async throws {
        func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw PisaError.message(message) }
        }
        guard let path = argument("--title-model-directory") else { throw PisaError.message("Provide the local title model directory") }
        let root = argument("--title-fixture-root").map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Titles-" + UUID().uuidString)
        let keep = argument("--title-fixture-root") != nil
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        let state = AppState(rootURL: root)
        try linkModel(from: URL(fileURLWithPath: path), into: root)
        func fixture(_ text: [String]) -> Meeting {
            var meeting = Meeting(title: "", source: "Аудиофайл")
            meeting.title = meeting.defaultTitle; meeting.automaticTitle = meeting.title
            meeting.status = .ready
            meeting.segments = text.enumerated().map { .init(start: Double($0.offset * 20), end: Double($0.offset * 20 + 18), speaker: $0.offset.isMultiple(of: 2) ? "Анна" : "Борис", text: $0.element) }
            meeting.duration = Double(text.count * 20)
            return meeting
        }
        let russian = fixture([
            "Сегодня обсуждаем запуск нового поиска в приложении. Проверили качество поиска организаций и исправили ошибки в подсказках.",
            "Для запуска поиска осталось завершить тестирование на небольшой группе пользователей. Анна отвечает за тесты, Борис за аналитику.",
            "Договорились выпустить новый поиск в декабре. До пятницы проверим метрики, после запуска сравним успешность поиска с прежней версией."
        ])
        state.update(russian)
        await state.nameCompletedMeeting(russian.id)
        let named = try state.library.read(russian.id)
        try check(named.titleOrigin == .generated && named.title.localizedCaseInsensitiveContains("поиск"), "Russian topic missing: \(named.title); \(state.message ?? "")")
        try check(named.status == .ready && named.segments == russian.segments, "Naming changed transcript")
        print("TITLE_RUSSIAN", named.title)

        var english = fixture(["We reviewed the marketing budget for next quarter. The advertising budget will increase by twenty percent. We agreed to spend more on search ads and reduce spending on social media campaigns."])
        english.segments[0].speaker = "Alice"
        state.update(english); await state.nameCompletedMeeting(english.id)
        let englishNamed = try state.library.read(english.id)
        try check(englishNamed.titleOrigin == .generated && englishNamed.title.localizedCaseInsensitiveContains("budget"), "English topic missing: \(englishNamed.title)")
        print("TITLE_ENGLISH", englishNamed.title)

        let long = fixture((0..<36).map { index in
            index == 35 ? "В итоге решили перенести запуск поиска на декабрь, сначала исправить ошибки и проверить метрики. Ответственные за запуск поиска — Анна и Борис." : "Обсуждаем запуск нового поиска. Проверяем качество поиска организаций, подсказки и метрики успешности. В тестовой группе ещё встречаются ошибки. Нужно проверить сценарии поиска по адресу и по названию, собрать обратную связь и исправить найденные проблемы перед запуском."
        })
        state.update(long); await state.nameCompletedMeeting(long.id)
        let longNamed = try state.library.read(long.id)
        try check(longNamed.titleOrigin == .generated && longNamed.title.localizedCaseInsensitiveContains("поиск"), "Long transcript topic missing: \(longNamed.title)")
        print("TITLE_LONG", longNamed.title)

        state.rename(named, to: "Мой обзор запуска")
        await state.nameCompletedMeeting(named.id)
        let reopened = AppState(rootURL: root)
        try check(reopened.meetings.first(where: { $0.id == named.id })?.title == "Мой обзор запуска", "Manual title changed on restart")
        try check(reopened.meetings.first(where: { $0.id == english.id })?.title == englishNamed.title, "Generated title changed on restart")
        state.search = "Мой обзор запуска"
        for _ in 0..<500 {
            if !state.searchInProgress { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try check(!state.searchInProgress, "Search did not finish")
        try check(state.filtered.contains(where: { $0.id == named.id }) && !state.filtered.contains(where: { $0.id == english.id || $0.id == long.id }), "Search did not use title")
        let exports = root.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let exported = try MarkdownExporter.export(longNamed, to: exports)
        try check(try String(contentsOf: exported, encoding: .utf8).contains("# " + longNamed.title), "Export title missing")

        let failingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Pisa-Title-Failure-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failing = AppState(rootURL: failingRoot)
        try Data("blocked".utf8).write(to: failingRoot.appendingPathComponent("Models"))
        let failed = fixture(["Обсудили запуск нового поиска."])
        failing.update(failed); await failing.nameCompletedMeeting(failed.id)
        try check(try failing.library.read(failed.id) == failed, "Title error changed successful transcript")
        try check(failing.message?.hasPrefix("Расшифровка сохранена.") == true, "Missing recoverable title error")
        print("MEETING_TITLES_TEST_OK local_inference russian english full_transcript manual_rename restart search export failure_preserves_transcript")
    }

    static func preview() throws {
        guard let path = argument("--title-fixture-root") else { throw PisaError.message("Provide the disposable fixture root") }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let state = AppState(rootURL: URL(fileURLWithPath: path))
        state.modelSetup.phase = .ready
        state.select(state.meetings.first(where: { $0.titleOrigin == .generated })?.id)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Pisa · Названия встреч"
        window.contentView = NSHostingView(rootView: MainView().environmentObject(state).preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU")))
        window.center(); window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        withExtendedLifetime((state, window)) { app.run() }
    }
}

private actor TitleCancellationTrigger {
    private var task: Task<String?, Error>?
    func track(_ task: Task<String?, Error>) { self.task = task }
    func schedule() {
        Task {
            // The phase fires immediately before respond; let its prefill/generation start.
            try? await Task.sleep(nanoseconds: 150_000_000)
            task?.cancel()
        }
    }
}
