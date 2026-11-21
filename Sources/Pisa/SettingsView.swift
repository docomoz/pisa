import SwiftUI
import AppKit

enum SettingsCheckbox: Hashable {
    case automaticRecording, backgroundTranscription, launchAtLogin, quietProcessing, autoExport, mcpAccess, automaticUpdates
}

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var updates: AppUpdates
    @AppStorage("settingsMCPClient") private var mcpClient = SettingsMCPClient.codex
    @State private var section = "Запись"
    @State private var showRecordingDetails = false
    private let storageScanner: SettingsStorageScanner

    init(initialSection: String = "Запись", updates: AppUpdates? = nil,
         scanStorage: @escaping @Sendable (MeetingLibrary) throws -> LibraryStorageUsage = { try $0.storageUsage() }) {
        _section = State(initialValue: initialSection)
        _updates = ObservedObject(wrappedValue: updates ?? .shared)
        storageScanner = SettingsStorageScanner(scan: scanStorage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            SectionHeading("Настройки", style: .window)
                .measuredForInterfaceTest(.settingsHeader)
            SettingsSectionPicker(selection: $section)
                .measuredForInterfaceTest(.settingsTabBar)
            if section == "Голоса" {
                SavedVoicesSettings()
                    .measuredForInterfaceTest(.settingsContent(section))
            } else if section == "Словарь" {
                VocabularyDictionaryView()
                    .measuredForInterfaceTest(.settingsContent(section))
            } else {
                settingsScroll
            }
            HStack(spacing: PisaDesign.Spacing.inline) {
                Image(nsImage: BrandMark.headerIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                screenText("Pisa \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .textStyle(PisaDesign.Typography.footnote)
                    .foregroundStyle(Color.mutedInk)
                Spacer()
                screenButton("Готово") { dismiss() }
                    .actionButton(.primary)
                    .keyboardShortcut(.cancelAction)
                    .measuredForInterfaceTest(.settingsDone)
            }
        }.dialogContent().frame(width: 900, height: 700)
            .background(SettingsInitialFocus().allowsHitTesting(false))
            .background(ClickToUnfocus())
    }

    private var settingsScroll: some View {
        GeometryReader { geometry in
            // A legacy scrollbar uses space only on overflowing pages. Keep
            // that gutter available on every grid so columns never shift.
            let style = NSScroller.preferredScrollerStyle
            let gutter = style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: style) : 0
            ScrollView {
                sectionGrid
                    .frame(width: max(0, geometry.size.width - gutter), alignment: .leading)
                    .measuredForInterfaceTest(.settingsContent(section))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, PisaDesign.Spacing.compact)
            }
            .id(section)
        }
    }

    @ViewBuilder private var sectionGrid: some View {
        switch section {
        case "Запись": recordingSettings
        case "Модель": modelSettings
        case "Экспорт": exportSettings
        case "Хранилище": StorageSettings(scanner: storageScanner)
        case "MCP": mcpSettings
        default: updateSettings
        }
    }

    private var updateSettings: some View {
        SettingsGrid(singleColumn: true) {
            SettingsSection("Обновления Pisa", subtitle: "Новые версии загружаются с GitHub") {
                settingsCheckboxGroup(.automaticUpdates) {
                    screenToggle("Устанавливать обновления автоматически", isOn: Binding(
                        get: { updates.installsAutomatically },
                        set: { updates.setAutomaticInstallation($0) }
                    )).disabled(!updates.isReady)
                } details: {
                    if updates.isReady {
                        SettingsHint("Если выключить, Pisa сообщит о новой версии и предложит установить её вручную")
                    } else {
                        SettingsHint(updates.startError ?? "Недоступно в этой сборке", warning: true)
                    }
                }
                screenButton("Проверить обновления") { updates.check() }
                    .actionButton().disabled(!updates.canCheck)
            }
            .settingsColumn(.settingsLeftColumn)
        }
    }

    private var exportSettings: some View {
        let hasFolder = state.preferences.exportBookmark != nil
        let unavailable = hasFolder && state.exportFolderUnavailable
        let status = SectionHeading.Accessory(
            unavailable ? "папка недоступна" : hasFolder ? "включён" : "выключен",
            color: unavailable ? .recordingRed : hasFolder ? .moss : .mutedInk
        )
        return SettingsGrid(singleColumn: true) {
            SettingsSection("Экспорт в Markdown", accessory: status) {
                settingsCheckboxGroup(.autoExport) {
                    screenToggle("Автоэкспорт расшифровок", isOn: Binding(
                        get: { state.preferences.exportBookmark != nil },
                        set: { enabled in
                            if enabled {
                                state.chooseExportFolder()
                            } else {
                                state.disableExportFolder()
                            }
                        }
                    ))
                } details: {
                    SettingsHint("Когда расшифровка готова, Pisa сохраняет текст, имена участников и временные метки. После правок файл обновляется автоматически, аудио остаётся в библиотеке.")
                }
                if hasFolder {
                    if let path = state.preferences.exportDisplayPath {
                        settingsPath(path).measuredForInterfaceTest(.exportPath)
                    }
                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                        screenButton(unavailable ? "Выбрать папку…" : "Выбрать другую папку…") {
                            state.chooseExportFolder()
                        }
                        .actionButton()
                        .measuredForInterfaceTest(.exportChooseFolder)
                        if unavailable {
                            SettingsHint("Папка недоступна. Выберите её заново, чтобы возобновить экспорт.", warning: true)
                                .measuredForInterfaceTest(.exportUnavailableNotice)
                        } else {
                            SettingsHint("Если папка синхронизируется с облаком, расшифровки могут попасть туда", warning: true)
                                .measuredForInterfaceTest(.exportCloudNotice)
                        }
                    }
                }
            }
            .settingsColumn(.settingsLeftColumn)
        }.onAppear { state.refreshExportFolderAccess() }
    }

    private var mcpSettings: some View {
        let configuration = mcpClient.configuration(commandPath: state.mcpPath)
        return SettingsGrid {
            SettingsSection("Доступ к встречам через MCP") {
                settingsCheckboxGroup(.mcpAccess) {
                    screenToggle("Разрешить MCP читать библиотеку", isOn: $state.preferences.mcpEnabled)
                        .onChange(of: state.preferences.mcpEnabled) { state.saveMCPSetting() }
                } details: {
                    SettingsHint("Клиент ищет реплики, читает расшифровки и видит папки. Ссылки открывают нужные фрагменты в Pisa. Аудио и изменение библиотеки недоступны.")
                        .measuredForInterfaceTest(.mcpAccessNotice)
                    SettingsHint("Облачная модель клиента может получить прочитанный текст", warning: true)
                    SettingsHint("Выключатель отзывает доступ и у уже запущенного клиента")
                }
            }
            .settingsColumn(.settingsLeftColumn)
            SettingsSection("Подключение") {
                SettingsMCPClientPicker(selection: $mcpClient)
                SettingsHint(mcpClient.instructions)
                ScrollView(.horizontal) {
                    screenText(verbatim: configuration)
                        .textStyle(PisaDesign.Typography.code)
                        .foregroundStyle(PisaDesign.Colors.paper)
                        .fixedSize()
                        .textSelection(.enabled)
                        .padding(PisaDesign.Spacing.content)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PisaDesign.Colors.ink, in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                screenButton("Скопировать") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration, forType: .string)
                }
                .actionButton()
                .measuredForInterfaceTest(.mcpCopyConfiguration)
                SettingsHint("Сервер работает на этом Mac без сетевого порта")
            }
            .disabled(!state.preferences.mcpEnabled)
            .opacity(state.preferences.mcpEnabled ? 1 : 0.55)
            .settingsColumn(.settingsRightColumn)
        }
    }

    private var modelSettings: some View {
        let setup = state.modelSetup
        let checksModels = setup.ready || setup.phase == .checking
        return SettingsGrid {
            SettingsSection("Parakeet v3", subtitle: "Локальное распознавание с перепроверкой терминов",
                            accessory: modelStatus, headingElement: .settingsModelHeading) {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                    screenButton(checksModels ? "Проверить модели" : "Скачать модели") {
                        if checksModels {
                            setup.check(presentWhenNeeded: false)
                        } else {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                setup.check(presentWhenNeeded: false)
                                setup.presented = true
                            }
                        }
                    }
                    .actionButton()
                    .disabled(setup.busy)
                    .measuredForInterfaceTest(.settingsModelAction)
                    if setup.phase == .failed, let error = setup.error {
                        SettingsHint(error, warning: true)
                    }
                    if !checksModels, !setup.busy, let bytes = setup.missingDownloadBytes, bytes > 0 {
                        SettingsHint("Размер загрузки — около \(modelDownloadSize(bytes))")
                            .measuredForInterfaceTest(.settingsModelDownloadSize)
                    }
                }
            }
            .settingsColumn(.settingsLeftColumn)
            SettingsSection("Производительность") {
                settingsCheckboxGroup(.quietProcessing) {
                    screenToggle("Тихая обработка", isOn: Binding(
                        get: { state.preferences.usesQuietProcessing },
                        set: { state.preferences.quietProcessing = $0; state.savePreferences() }
                    ))
                } details: {
                    SettingsHint("Меньше параллельной нагрузки и паузы между фрагментами. Расшифровка займёт больше времени.")
                }
            }
            .settingsColumn(.settingsRightColumn)
            modelFolder
        }.onAppear {
            if !setup.busy, !setup.ready, setup.missingDownloadBytes == nil {
                setup.check(presentWhenNeeded: false)
            }
        }
    }

    private var modelStatus: SectionHeading.Accessory {
        switch state.modelSetup.phase {
        case .checking: return .init("Проверяем…")
        case .available: return .init("Нужны модели", color: .recordingRed)
        case .downloading: return .init("Скачиваем…")
        case .ready: return .init("✓ Готова", color: .moss)
        case .failed: return .init("Ошибка", color: .recordingRed)
        }
    }

    private var modelFolder: some View {
        SettingsSection("Папка модели", headingElement: .settingsModelFolder) {
            if let path = state.modelURL()?.path ?? state.preferences.parakeetModelDisplayPath {
                settingsPath(path).measuredForInterfaceTest(.settingsModelPath)
            }
            screenButton("Выбрать папку модели…") { state.chooseModel() }
                .actionButton()
                .disabled(state.modelSetup.busy)
                .measuredForInterfaceTest(.settingsModelChooseFolder)
        }
    }

    private var recordingSettings: some View {
        SettingsGrid {
            SectionHeading("Источники звука",
                           subtitle: "Микрофон и системный звук Mac. Начните запись заранее и откройте встречу в любом приложении или браузере.",
                           style: .settings)
                .measuredForInterfaceTest(.settingsHeading("Источники звука"))
                .settingsColumn(.settingsLeftColumn)
            SettingsSection("Разрешения macOS", subtitle: "Откроют нужный раздел Системных настроек") {
                SettingsActionGroup {
                    Button { NSWorkspace.shared.open(CapturePermission.microphone.settingsURL) } label: {
                        screenLabel("Микрофон", systemImage: "mic")
                    }.actionButton()
                    Button { NSWorkspace.shared.open(CapturePermission.systemAudio.settingsURL) } label: {
                        screenLabel("Системный звук", systemImage: "speaker.wave.2")
                    }.actionButton()
                }.labelStyle(AlignedIconLabelStyle())
            }
            .settingsColumn(.settingsRightColumn)
            SettingsSection("Автозапись", accessory: .init("эксперимент")) {
                settingsCheckboxGroup(.automaticRecording) {
                    screenToggle("Автоматический старт и стоп", isOn: Binding(
                        get: { state.preferences.automaticRecording },
                        set: { state.setAutomatic($0) }
                    ))
                } details: {
                    let start = Int(CallDetector.defaultStartDelay)
                    let stop = Int(CallDetector.defaultStopDelay)
                    SettingsHint("Старт через \(start) с после того, как звонок займёт микрофон. Стоп через \(stop) с после того, как микрофон освободится.")
                }
                recordingDisclosure
            }
            LaunchAtLoginSettings(launchAtLogin: state.launchAtLogin, automaticRecording: state.preferences.automaticRecording)
            SettingsSection("Фоновая расшифровка") {
                settingsCheckboxGroup(.backgroundTranscription) {
                    screenToggle("Расшифровывать во время записи", isOn: Binding(
                        get: { state.preferences.usesBackgroundTranscription },
                        set: { state.setBackgroundTranscription($0) }
                    ))
                } details: {
                    SettingsHint("Черновик появляется во время звонка, после остановки дорабатывается остаток. Пауза распознавания не останавливает запись.")
                }
            }
        }
    }

    private var recordingDisclosure: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
            Button { showRecordingDetails.toggle() } label: {
                HStack(spacing: PisaDesign.Spacing.inline) {
                    Image(systemName: showRecordingDetails ? "chevron.down" : "chevron.right")
                        .font(PisaDesign.Typography.Icon.disclosure)
                        .frame(width: PisaDesign.Spacing.related)
                    screenText("Как работает и ограничения")
                    Spacer(minLength: PisaDesign.Spacing.none)
                }
                .contentShape(Rectangle())
            }
            .shapeAwarePlainButton()
            .foregroundStyle(Color.moss)
            .accessibilityValue(showRecordingDetails ? "Развёрнуто" : "Свёрнуто")
            .measuredForInterfaceTest(.settingsRecordingDisclosure)
            if showRecordingDetails {
                SettingsHint("Pisa следит за использованием микрофона другими приложениями, а не за громкостью звука. Диктовка и тест микрофона тоже могут запустить запись. Звонки без доступа к микрофону не определяются. Отключение микрофона в приложении может вызвать автостоп. Если начать запись вручную до встречи, автостоп включится только после обнаружения звонка.")
                    .measuredForInterfaceTest(.settingsRecordingDetails)
            }
        }
    }
}

private struct LaunchAtLoginSettings: View {
    @ObservedObject var launchAtLogin: LaunchAtLogin
    let automaticRecording: Bool

    var body: some View {
        SettingsSection("Запуск Pisa") {
            settingsCheckboxGroup(.launchAtLogin) {
                screenToggle(LaunchAtLogin.title, isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
            } details: {
                if let error = launchAtLogin.error {
                    SettingsHint(error, warning: true)
                } else if launchAtLogin.status == .requiresApproval {
                    SettingsHint("Разрешите запуск Pisa в системных настройках macOS", warning: true)
                        .measuredForInterfaceTest(.settingsLoginApproval)
                } else if automaticRecording && !launchAtLogin.isEnabled {
                    SettingsHint("Без этого автозапись не сработает после перезагрузки Mac", warning: true)
                        .measuredForInterfaceTest(.settingsLoginWarning)
                } else {
                    SettingsHint("Pisa откроется автоматически при входе в macOS")
                }
            }
        }
        .onAppear { launchAtLogin.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin.refresh()
        }
    }
}

private func settingsCheckboxGroup<Checkbox: View, Details: View>(
    _ id: SettingsCheckbox,
    @ViewBuilder checkbox: () -> Checkbox,
    @ViewBuilder details: () -> Details
) -> some View {
    VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
        checkbox().environment(\.settingsCheckboxLabel, id).measuredForInterfaceTest(.settingsCheckbox(id))
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact, content: details)
            .measuredForInterfaceTest(.settingsCheckboxDetails(id))
            .padding(.leading, PisaDesign.Metrics.checkboxSide + PisaDesign.Spacing.inline)
    }
}

private func settingsPath(_ path: String) -> some View {
    screenText(verbatim: path)
        .textStyle(PisaDesign.Typography.code)
        .foregroundStyle(Color.mutedInk)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .screenHelp(path)
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let accessory: SectionHeading.Accessory?
    let headingElement: InterfaceLayoutElement
    let content: Content

    init(_ title: String, subtitle: String? = nil, accessory: SectionHeading.Accessory? = nil,
         headingElement: InterfaceLayoutElement? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.headingElement = headingElement ?? .settingsHeading(title)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: subtitle == nil ? PisaDesign.Spacing.related : PisaDesign.Spacing.content) {
            SectionHeading(title, subtitle: subtitle, style: .settings, accessory: accessory)
                .measuredForInterfaceTest(headingElement)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsActionGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PisaDesign.Spacing.inline, content: content)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline, content: content)
        }
    }
}

private struct SettingsGrid<Content: View>: View {
    var singleColumn = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        SettingsGridLayout() { content() }
            .overlay {
                if !singleColumn {
                    Rectangle().fill(Color.black.opacity(0.08))
                        .frame(width: PisaDesign.Metrics.separatorWidth)
                        .measuredForInterfaceTest(.settingsGridDivider)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }
}

private extension View {
    func settingsColumn(_ element: InterfaceLayoutElement) -> some View {
        frame(maxWidth: .infinity, alignment: .leading).measuredForInterfaceTest(element)
    }
}

// Measure each row at the same two fixed column widths. A tall cell grows
// its own row and moves the next pair together.
private struct SettingsGridLayout: Layout {
    private let gap = PisaDesign.Spacing.section

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = proposed
        } else {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
            width = 2 * ideal + gap
        }
        let heights = rowHeights(width: columnWidth(total: width), subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + CGFloat(max(0, heights.count - 1)) * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = columnWidth(total: bounds.width)
        let rows = rowHeights(width: width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in rows.enumerated() {
            let left = row * 2
            let cell = ProposedViewSize(width: width, height: nil)
            subviews[left].place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: cell)
            if left + 1 < subviews.count {
                subviews[left + 1].place(at: CGPoint(x: bounds.minX + width + gap, y: y), anchor: .topLeading, proposal: cell)
            }
            y += height + gap
        }
    }

    private func columnWidth(total: CGFloat) -> CGFloat {
        max(0, (total - gap) / 2)
    }

    private func rowHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let cell = ProposedViewSize(width: width, height: nil)
        return stride(from: 0, to: subviews.count, by: 2).map { left in
            subviews[left..<min(left + 2, subviews.count)].map { $0.sizeThatFits(cell).height }.max() ?? 0
        }
    }
}

private enum SettingsMCPClient: String, CaseIterable {
    case codex = "Codex"
    case claudeCode = "Claude Code"
    case claudeDesktop = "Claude Desktop"
    case cursor = "Cursor"

    var instructions: String {
        switch self {
        case .codex: "Добавьте в ~/.codex/config.toml"
        case .claudeCode: "Выполните команду в Терминале"
        case .claudeDesktop: "Добавьте в claude_desktop_config.json и перезапустите Claude"
        case .cursor: "Добавьте в ~/.cursor/mcp.json"
        }
    }

    func configuration(commandPath: String) -> String {
        switch self {
        case .codex: MCPClientConfiguration.toml(commandPath: commandPath)
        case .claudeCode: MCPClientConfiguration.claudeCode(commandPath: commandPath)
        case .claudeDesktop: MCPClientConfiguration.json(commandPath: commandPath)
        case .cursor: MCPClientConfiguration.json(commandPath: commandPath, explicitStdio: true)
        }
    }
}

private struct SettingsMCPClientPicker: View {
    @Binding var selection: SettingsMCPClient
    @FocusState private var focused: SettingsMCPClient?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            clientRow(SettingsMCPClient.allCases)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.compact) {
                clientRow([.codex, .claudeCode])
                clientRow([.claudeDesktop, .cursor])
            }
        }
        .padding(PisaDesign.Spacing.compact)
        .plainSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Клиент MCP")
    }

    private func clientRow(_ clients: [SettingsMCPClient]) -> some View {
        HStack(spacing: PisaDesign.Spacing.compact) {
            ForEach(clients, id: \.self) { client in
                Button { selection = client } label: {
                    screenText(client.rawValue)
                        .textStyle(PisaDesign.Typography.detailMedium)
                        .fixedSize()
                        .padding(.horizontal, PisaDesign.Spacing.inline)
                        .frame(height: PisaDesign.Metrics.smallHeight)
                        .background(selection == client ? Color.paper : .clear,
                                    in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                        .contentShape(Rectangle())
                }
                .shapeAwarePlainButton()
                .focused($focused, equals: client)
                .accessibilityAddTraits(selection == client ? .isSelected : [])
                .measuredForInterfaceTest(.settingsMCPClient(client.rawValue))
                .onMoveCommand { direction in
                    let all = SettingsMCPClient.allCases
                    guard direction == .left || direction == .right, let index = all.firstIndex(of: client) else { return }
                    let next = min(all.count - 1, max(0, index + (direction == .right ? 1 : -1)))
                    selection = all[next]
                    focused = all[next]
                }
            }
        }
    }
}

private struct SettingsStorageScanner: Sendable {
    let scan: @Sendable (MeetingLibrary) throws -> LibraryStorageUsage
}

private struct StorageSettings: View {
    @EnvironmentObject private var state: AppState
    let scanner: SettingsStorageScanner
    @State private var weeks = 2
    @State private var usage: LibraryStorageUsage?
    @State private var scanFailed = false
    @State private var refreshID = 0
    @State private var confirmation: AudioCleanupPlan?
    @State private var result: AudioCleanupResult?

    private var cleanupPlan: AudioCleanupPlan? {
        guard let usage, let cutoff = Calendar.current.date(byAdding: .day, value: -7 * weeks, to: .now) else { return nil }
        return state.audioCleanupPlan(olderThan: cutoff, usage: usage)
    }

    var body: some View {
        SettingsGrid {
            SettingsSection("Место на Mac") {
                if let usage {
                    let recordings = state.meetings.count { meeting in
                        meeting.audioFiles.contains { usage.audioFiles[$0] != nil }
                    }
                    storageRow("Аудиозаписи · \(meetingCount(recordings))", bytes: usage.audioBytes)
                    storageRow("Расшифровки и данные встреч", bytes: usage.meetingBytes)
                    storageRow("Модели и другие файлы Pisa", bytes: usage.otherBytes)
                    Divider()
                    storageRow("Всего", bytes: usage.totalBytes, total: true)
                } else if scanFailed {
                    SettingsHint("Не удалось посчитать размер файлов")
                    screenButton("Повторить") { refreshID += 1 }.actionButton()
                } else {
                    SettingsHint("Считаем размер файлов…")
                        .measuredForInterfaceTest(.settingsStorageScanning)
                }
            }
            .settingsColumn(.settingsLeftColumn)
            SettingsSection("Очистка аудиозаписей", subtitle: "Удаляется звук обработанных встреч. Расшифровки и заметки остаются.") {
                let plan = cleanupPlan
                let canCleanUp = plan?.filesByMeeting.isEmpty == false
                SettingsActionGroup { cleanupActions(canCleanUp: canCleanUp) }
                if let result {
                    if result.failedMeetings > 0 {
                        SettingsHint("Не удалось полностью очистить аудио. Встреч с ошибками: \(result.failedMeetings). Освобождено \(storageSize(result.bytes)).")
                    } else if result.meetings > 0 {
                        SettingsHint("Освобождено \(storageSize(result.bytes)). Встреч очищено: \(result.meetings).")
                            .measuredForInterfaceTest(.settingsStorageResult)
                    } else {
                        SettingsHint("Подходящих аудиозаписей больше нет")
                    }
                } else if let plan {
                    if plan.filesByMeeting.isEmpty {
                        SettingsHint("Подходящих аудиозаписей нет")
                    } else {
                        SettingsHint("К удалению: \(meetingCount(plan.filesByMeeting.count)) · \(storageSize(plan.bytes))")
                            .measuredForInterfaceTest(.settingsStorageEstimate)
                    }
                }
            }
            .settingsColumn(.settingsRightColumn)
        }
        .sheet(item: $confirmation) { plan in
            ConfirmationSheet(
                title: "Удалить старые аудиозаписи?",
                message: "К удалению: \(meetingCount(plan.filesByMeeting.count)) · \(storageSize(plan.bytes)). Аудио удалится навсегда. Расшифровки и заметки останутся.",
                actionTitle: "Удалить аудио",
                role: .destructive
            ) {
                guard let usage else { return }
                result = state.cleanUpAudio(plan, usage: usage)
                refreshID += 1
            }
        }
        .task(id: refreshID) { await refreshStorage() }
    }

    @ViewBuilder
    private func cleanupActions(canCleanUp: Bool) -> some View {
        NativeActionMenu {
            [1, 2, 4, 8, 12].map { value in
                NativeActionMenuItem(ageLabel(value)) {
                    weeks = value
                    result = nil
                }
            }
        } label: {
            HStack(spacing: PisaDesign.Spacing.inline) {
                screenText(ageLabel(weeks))
                Image(systemName: "chevron.down").font(PisaDesign.Typography.Icon.disclosure)
            }
        }
        .actionButton()
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Возраст аудиозаписей")
        .accessibilityValue(typographicText(ageLabel(weeks)))
        .measuredForInterfaceTest(.settingsStorageAge)

        screenButton("Освободить место") { confirmation = cleanupPlan }
            .actionButton()
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canCleanUp)
            .measuredForInterfaceTest(.settingsStorageAction)
    }

    private func storageRow(_ label: String, bytes: Int64, total: Bool = false) -> some View {
        HStack(spacing: PisaDesign.Spacing.related) {
            screenText(label)
            Spacer()
            screenText(storageSize(bytes)).monospacedDigit().fixedSize()
        }.textStyle(total ? PisaDesign.Typography.bodyStrong : PisaDesign.Typography.body)
    }

    private func refreshStorage() async {
        usage = nil
        scanFailed = false
        let library = state.library
        let scanner = scanner
        let scan = Task.detached(priority: .utility) { try scanner.scan(library) }
        let scanned = try? await withTaskCancellationHandler(operation: { try await scan.value }, onCancel: { scan.cancel() })
        guard !Task.isCancelled else { return }
        usage = scanned
        scanFailed = scanned == nil
    }

    private func ageLabel(_ weeks: Int) -> String {
        "Старше \(weeks) \(weeks == 1 ? "недели" : "недель")"
    }

    private func meetingCount(_ count: Int) -> String {
        let noun: String
        switch (count % 10, count % 100) {
        case (_, 11...14): noun = "встреч"
        case (1, _): noun = "встреча"
        case (2...4, _): noun = "встречи"
        default: noun = "встреч"
        }
        return "\(count) \(noun)"
    }

    private func storageSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0 Б" }
        let unit = bytes >= 1_000_000_000 ? (1_000_000_000.0, "ГБ")
            : bytes >= 1_000_000 ? (1_000_000.0, "МБ") : (1_000.0, "КБ")
        let amount = max(0.1, Double(bytes) / unit.0)
        let formatted = amount.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU")))
        return "\(formatted) \(unit.1)"
    }
}

// Clear only the initial sheet focus. Keyboard Tab navigation remains available.
private struct SettingsInitialFocus: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FocusView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class FocusView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in window?.makeFirstResponder(nil) }
        }
    }
}
