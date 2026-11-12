import AppKit
import AVFoundation
import Combine
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
        if CommandLine.arguments.contains("--audio-saved-preview") {
            fixture.status = .recorded
            fixture.segments = []
            let mic = "waveform-mic.caf", remote = "waveform-remote.caf"
            try Self.writeAudio(to: state.library.audioURL(mic), duration: 42, frequency: 180)
            try Self.writeAudio(to: state.library.audioURL(remote), duration: 34, frequency: 260)
            fixture.audioFiles = [mic, remote]
            fixture.audioOffsets = [remote: 5]
            fixture.duration = 42
        }
        let recordingPreview = CommandLine.arguments.contains("--recording-transcription-preview")
        if recordingPreview {
            fixture.status = .failed
            fixture.liveCommittedUntil = 160
        } else if CommandLine.arguments.contains("--processing-preview") {
            fixture.status = .processing
        }
        meeting = fixture
        state.update(fixture)
        state.select(fixture.id)
        if recordingPreview {
            try Self.prepareModelPath(for: state)
            var saved = Meeting(title: "Сохранённое аудио", source: state.source)
            saved.audioFiles = fixture.audioFiles
            saved.duration = fixture.duration
            state.update(saved)
            let current = Meeting(title: "Текущая запись", source: state.source)
            state.update(current)
            state.beginRecordingSession(current, automatic: false)
        } else if CommandLine.arguments.contains("--processing-preview") {
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
            .preferredColorScheme(.light).environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.appTextScale, CommandLine.arguments.contains("--large-text-preview") ? 1.2 :
                CommandLine.arguments.contains("--medium-text-preview") ? 1.1 : 1))
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

    private static func writeAudio(to url: URL, duration: Int, frequency: Double) throws {
        let rate = 16_000
        let frames = rate * duration
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { throw PisyaError.message("Не удалось подготовить тестовое аудио") }
        buffer.frameLength = AVAudioFrameCount(frames)
        for frame in 0..<frames {
            let time = Double(frame) / Double(rate)
            let phrase = max(0, sin(time * 1.8 + frequency))
            let syllable = pow(sin(time * (8 + frequency / 100)), 4)
            samples[frame] = Float(0.04 * phrase * syllable * sin(time * frequency * 2 * .pi))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
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
        guard let folderID = state.saveFolder("Работа"),
              let moveItem = MeetingActionSet(state: state, meeting: processing).contextMenuItems.first(where: \.hasSubmenu),
              moveItem.isEnabled, let submenu = moveItem.submenu,
              let destination = submenu.item(withTitle: "Работа") else {
            throw PisyaError.message("Перемещение из контекстного меню недоступно во время расшифровки")
        }
        _ = NSApplication.shared
        submenu.performActionForItem(at: submenu.index(of: destination))
        guard try state.library.read(processing.id).folderID == folderID else {
            throw PisyaError.message("Папка записи не сохранилась во время расшифровки")
        }
        state.moveToNewFolder(processing, name: "Планы", symbol: "folder")
        guard let newFolder = state.folders.first(where: { $0.name == "Планы" }),
              try state.library.read(processing.id).folderID == newFolder.id else {
            throw PisyaError.message("Не удалось переместить запись в новую папку во время расшифровки")
        }
        var completed = try state.library.read(processing.id)
        guard completed.title == "Название во время расшифровки", completed.segments == processing.segments,
              completed.status == .processing, state.processingID == processing.id else {
            throw PisyaError.message("Перемещение изменило название, текст или состояние расшифровки")
        }
        completed.status = .ready
        _ = completed.applyGeneratedTitle("Автоматическое название")
        try state.library.save(completed)
        let finished = try state.library.read(processing.id)
        guard finished.title == "Название во время расшифровки", finished.folderID == newFolder.id else {
            throw PisyaError.message("Название или папка изменились после завершения расшифровки")
        }
        state.processingID = active
        state.cancelQueued(first.id)
        guard !state.isQueued(first.id), state.isQueued(second.id), state.processingID == active,
              try state.library.read(first.id).title == "Название в очереди" else { throw PisyaError.message("Отмена изменила запись или другую задачу") }
        state.enqueue(first.id)
        guard state.isQueued(first.id) else { throw PisyaError.message("Запись нельзя снова добавить в очередь") }
        state.cancelQueued(first.id); state.cancelQueued(second.id); state.cancelQueued(active)
        guard state.processingID == active else { throw PisyaError.message("Отмена очереди остановила обработку") }
    }

    static func testQueuedTurboTranscription() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Queued-Turbo-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        try prepareModelPath(for: state)
        let blocker = Meeting(title: "Текущая обработка", source: state.source)
        let normal = Meeting(title: "Обычная обработка", source: state.source)
        let requeued = Meeting(title: "Повторно в очереди", source: state.source)
        let batch = Meeting(title: "Новая расшифровка", source: state.source)
        var resume = Meeting(title: "Продолжение черновика", source: state.source)
        resume.status = .failed
        resume.liveCommittedUntil = 3
        for meeting in [blocker, normal, requeued, batch, resume] { state.update(meeting) }
        state.enqueue(blocker.id)
        state.enqueue(normal.id)
        state.enqueue(requeued.id)
        state.enqueue(batch.id, reprocess: true)
        state.enqueue(resume.id)

        guard !state.canUseTurboTranscription(batch.id) else {
            throw PisyaError.message("Турбо-режим доступен в очереди при тихой обработке")
        }
        state.preferences.quietProcessing = false
        guard state.canUseTurboTranscription(batch.id), state.canUseTurboTranscription(resume.id) else {
            throw PisyaError.message("Турбо-режим недоступен для записей в очереди")
        }
        state.setTurboTranscription(true, for: normal.id)
        state.preferences.quietProcessing = true
        state.preferences.quietProcessing = false
        state.setTurboTranscription(true, for: requeued.id)
        state.cancelQueued(requeued.id)
        state.enqueue(requeued.id)
        state.setTurboTranscription(true, for: batch.id)
        state.setTurboTranscription(true, for: resume.id)
        guard state.processingID == blocker.id, !state.turboTranscriptionEnabled else {
            throw PisyaError.message("Турбо-режим в очереди изменил текущую обработку")
        }

        var turboStarts: [UUID] = []
        let observation = state.$turboTranscriptionEnabled.sink { enabled in
            if enabled, let id = state.processingID { turboStarts.append(id) }
        }
        defer { observation.cancel() }
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)
        guard turboStarts == [batch.id, resume.id], !state.turboTranscriptionEnabled,
              [normal, requeued, batch, resume].allSatisfy({ !state.isQueued($0.id) }) else {
            throw PisyaError.message("Очередь запустила обработку с неверным турбо-режимом")
        }
    }

    static func testTranscriptionDuringRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Pisya-Recording-Queue-Test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = AppState(rootURL: root)
        try prepareModelPath(for: state)
        var saved = Meeting(title: "Предыдущая встреча", source: state.source)
        saved.liveCommittedUntil = 3
        saved.audioFiles = ["saved-mic.caf"]
        saved.segments = [.init(start: 0, end: 2, speaker: "Я", text: "Сохранённая реплика")]
        try writeAudio(to: state.library.audioURL(saved.audioFiles[0]), duration: 6, frequency: 180)
        state.update(saved)
        state.enqueue(saved.id)
        guard state.processingID == saved.id else { throw PisyaError.message("Не запустилась расшифровка предыдущей встречи") }

        guard !state.canUseTurboTranscription(saved.id) else {
            throw PisyaError.message("Турбо-режим доступен при включённой тихой обработке")
        }
        state.preferences.quietProcessing = false
        state.setTurboTranscription(true, for: saved.id)
        guard state.turboTranscriptionEnabled else {
            throw PisyaError.message("Турбо-режим не включился для сохранённого аудио")
        }

        let current = Meeting(title: "Текущая встреча", source: state.source)
        state.update(current)
        state.beginRecordingSession(current, automatic: false)
        state.setTurboTranscription(false, for: current.id)
        guard state.canUseTurboTranscription(saved.id), state.turboTranscriptionEnabled else {
            throw PisyaError.message("Текущая запись повлияла на турбо-режим предыдущей встречи")
        }
        state.preferences.quietProcessing = true
        guard !state.canUseTurboTranscription(saved.id), !state.turboTranscriptionEnabled else {
            throw PisyaError.message("Тихая обработка не отключила турбо-режим")
        }
        state.preferences.quietProcessing = false
        guard !state.turboTranscriptionEnabled else {
            throw PisyaError.message("Турбо-режим включился без запроса")
        }
        state.setTurboTranscription(true, for: saved.id)
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)
        guard state.recordingMeetingID == current.id else { throw PisyaError.message("Отмена расшифровки остановила запись") }

        state.enqueue(saved.id)
        let resumed = try state.library.read(saved.id)
        guard state.processingID == saved.id, resumed.liveCommittedUntil == 3, resumed.segments == saved.segments else {
            throw PisyaError.message("Не удалось продолжить предыдущую расшифровку с сохранённого места во время записи")
        }
        guard state.canUseTurboTranscription(saved.id), !state.turboTranscriptionEnabled else {
            throw PisyaError.message("Турбо-режим сохранился после остановки расшифровки")
        }
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)

        state.enqueue(current.id)
        let live = try state.library.read(current.id)
        guard state.recordingMeetingID == current.id, state.processingID == current.id,
              live.status == .processing, live.liveCommittedUntil == 0 else {
            throw PisyaError.message("Текущая запись не запустила черновик с начала записанного аудио")
        }
        state.setTurboTranscription(true, for: current.id)
        guard !state.canUseTurboTranscription(current.id), !state.turboTranscriptionEnabled else {
            throw PisyaError.message("Турбо-режим доступен при расшифровке текущей записи")
        }
        state.recording = false
        state.cancelProcessing()
        try await waitForTranscriptionToStop(state)
    }

    private static func prepareModelPath(for state: AppState) throws {
        // The test covers task selection before inference. A live task waits for capture boundaries.
        let model = state.library.root.appendingPathComponent("Models/Qwen3-ASR")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: model.appendingPathComponent("config.json"))
        state.modelSetup.phase = .ready
    }

    private static func waitForTranscriptionToStop(_ state: AppState) async throws {
        for _ in 0..<200 {
            if state.processingID == nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw PisyaError.message("Обработка не остановилась")
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
