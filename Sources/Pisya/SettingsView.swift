import SwiftUI
import AppKit
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var section = "Запись"
    @State private var showRecordingDetails = false
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            HStack { screenText("Настройки").font(.appFont(size: 26, weight: .semibold)); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.appFont(size: 20, weight: .semibold)).foregroundStyle(Color.mutedInk) }.shapeAwarePlainButton(Circle()).screenHelp("Закрыть настройки").accessibilityLabel("Закрыть настройки") }
            SettingsSectionPicker(selection: $section)
            ScrollView {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                    switch section {
                    case "Запись":
                        recordingSettings
                    case "Модель":
                        columns {
                        block("Qwen3-ASR", "Локальное распознавание русской речи на Apple Silicon") {
                            screenToggle("Тихая обработка", isOn: Binding(get: { state.preferences.usesQuietProcessing }, set: { state.preferences.quietProcessing = $0; state.savePreferences() }))
                            screenText("Меньше параллельной нагрузки и паузы между фрагментами. Расшифровка займёт больше времени.").font(.appFont(size: 15)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                            screenLabel(state.modelReady ? "Модель готова" : "Модели ещё не установлены", systemImage: state.modelReady ? "checkmark.circle.fill" : "externaldrive").foregroundStyle(Color.moss)
                            if let url = state.modelURL() { screenText(verbatim: url.path).font(Font(NSFont.monospacedSystemFont(ofSize: 15, weight: .regular))).fixedSize(horizontal: false, vertical: true).foregroundStyle(Color.mutedInk).textSelection(.enabled) }
                            screenButton("Выбрать папку модели…") { state.chooseModel() }.actionButton()
                            screenButton(state.modelReady ? "Проверить и установить модели…" : "Загрузить модели…") {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { state.modelSetup.check(); state.modelSetup.presented = true }
                            }.actionButton()
                            screenText("Pisya загрузит проверенные модели речи и участников с Hugging Face — около 3 ГБ. Распознавание выполняется на Mac. Также можно выбрать свою папку MLX-модели Qwen3-ASR.").font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        block("Словарь распознавания", "Чтобы Pisya точнее записывала имена и названия в вашей речи и речи собеседников") {
                            screenText("Например, добавьте «2ГИС», если вместо него получается «два гис»")
                                .font(.appFont(size: 15)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                            TextEditor(text: $state.preferences.vocabulary)
                                .font(.appFont(size: 16))
                                .scrollContentBackground(.hidden)
                                .frame(height: 180)
                                .padding(PisyaDesign.Spacing.inline)
                                .background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)
                                        .strokeBorder(Color.mutedInk.opacity(0.25), lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                                .accessibilityLabel("Словарь распознавания")
                                .accessibilityHint("Введите слова через запятую или с новой строки")
                                .onChange(of: state.preferences.vocabulary) { state.savePreferences() }
                            screenText("Укажите нужное написание слов через запятую или с новой строки. Можно оставить поле пустым.")
                                .font(.appFont(size: 15)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                        }


                            }
                        }
                    case "Экспорт":
                        columns {
                        block("Папка для расшифровок", "Markdown — для обычной папки, Dropbox или Obsidian") {
                            if let path = state.preferences.exportDisplayPath { screenText(verbatim: path).font(.appFont(size: 16)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } else { screenText("Автоэкспорт выключен").foregroundStyle(Color.mutedInk) }
                            HStack(spacing: PisyaDesign.Spacing.related) { screenButton("Выбрать папку…") { state.chooseExportFolder() }.actionButton(); if state.preferences.exportBookmark != nil { screenButton("Отключить") { state.preferences.exportBookmark = nil; state.preferences.exportDisplayPath = nil; state.savePreferences() }.actionButton() } }
                            screenText("После расшифровки и последующих правок файл обновляется автоматически. В него входят текст, участники и временные метки. Аудио остаётся в библиотеке.").font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        block("Если папка синхронизируется", "Dropbox, iCloud или другой сервис могут отправлять её содержимое в облако") { screenText("Выбор такой папки разрешает выгрузку текстов через приложение синхронизации. Это отдельно от локального распознавания.").font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true) }

                            }
                        }
                    default:
                        columns {
                        block("Доступ к встречам через MCP", "Локальный процесс · только чтение · без открытого сетевого порта") {
                            screenToggle("Разрешить MCP читать библиотеку", isOn: $state.preferences.mcpEnabled).onChange(of: state.preferences.mcpEnabled) { state.savePreferences() }
                            screenText("Подключённый клиент сможет искать встречи и читать расшифровки. Если клиент использует облачную модель, прочитанный текст может уйти к ней. Доступ к аудио и изменениям библиотеки не предоставляется.").font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        block("Подключение", "Добавьте этот локальный сервер в настройки вашего клиента") {
                            screenText(verbatim: "[mcp_servers.pisya]\ncommand = \"\(state.mcpPath)\"")
                                .font(Font(NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)))
                                .foregroundStyle(PisyaDesign.Colors.paper)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(PisyaDesign.Spacing.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(PisyaDesign.Colors.ink, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                            screenButton("Скопировать конфигурацию") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("[mcp_servers.pisya]\ncommand = \"\(state.mcpPath)\"", forType: .string) }.actionButton()
                            screenText("Инструменты: list_meetings, search_meetings, read_transcript. Выключатель отзывает доступ и у уже запущенного клиента.").font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                        }
                            }
                        }

                    }
                }.lineSpacing(PisyaDesign.Spacing.textLine).padding(.vertical, 4)
            }.id(section)
            HStack { screenText("Pisya \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · ранняя версия").font(.appFont(size: 15)).foregroundStyle(Color.mutedInk); Spacer(); screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction) }
        }.actionControls().font(.appFont(size: 16)).controlSize(.large).padding(PisyaDesign.Spacing.sheetInset).frame(width: 900, height: 700).popupCanvas()
            .background(SettingsInitialFocus().allowsHitTesting(false))
            .background(ClickToUnfocus())
    }
    private var recordingSettings: some View {
        HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                block("Источники звука", "Микрофон и системный звук") {
                    screenText("Начните запись заранее, затем откройте встречу в любом приложении или браузере. Записываются и другие звуки Mac.")
                        .font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
                block("Автозапись", "Экспериментальная функция") {
                    screenToggle("Автоматический старт и стоп", isOn: Binding(get: { state.preferences.automaticRecording }, set: { state.setAutomatic($0) }))
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        screenLabel("Старт — через 3 секунды", systemImage: "record.circle")
                        screenLabel("Стоп — через 45 секунд без микрофона", systemImage: "stop.circle").fixedSize(horizontal: false, vertical: true)
                    }.font(.appFont(size: 16)).fixedSize(horizontal: false, vertical: true)
                    screenText("Ориентируется на использование микрофона другими приложениями, а не на громкость звука.")
                        .font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                    // Keep the disclosure and its text together so the block's row spacing
                    // cannot add a second gap between the heading and its content.
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        Button { showRecordingDetails.toggle() } label: {
                            HStack(spacing: PisyaDesign.Spacing.inline) {
                                Image(systemName: showRecordingDetails ? "chevron.down" : "chevron.right").font(.appFont(size: 11, weight: .semibold)).frame(width: 12)
                                screenText("Как работает и ограничения")
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.shapeAwarePlainButton().foregroundStyle(Color.moss)
                            .accessibilityValue(showRecordingDetails ? "Развёрнуто" : "Свёрнуто")
                        if showRecordingDetails {
                            screenText("Диктовка и тест микрофона тоже могут запустить запись. Звонки без доступа к микрофону не определяются. Отключение микрофона в приложении может вызвать автостоп. Если вы начали запись вручную до встречи, автостоп включится только после обнаружения звонка.")
                                .font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                block("Разрешения macOS", "Нужны для записи вашего голоса и собеседников") {
                    Button { NSWorkspace.shared.open(CapturePermission.microphone.settingsURL) } label: { screenLabel("Микрофон…", systemImage: "mic") }.actionButton()
                    Button { NSWorkspace.shared.open(CapturePermission.systemAudio.settingsURL) } label: { screenLabel("Системный звук…", systemImage: "speaker.wave.2") }.actionButton()
                }
                block("Хранение аудио", "На этом Mac") {
                    screenText("Оригиналы сохраняются без автоматического удаления. В папку экспорта отправляется только текст.")
                        .font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
                block("Фоновая расшифровка", "Черновик во время звонка") {
                    screenToggle("Расшифровывать во время записи", isOn: Binding(get: { state.preferences.usesBackgroundTranscription }, set: { state.setBackgroundTranscription($0) }))
                    screenText("После остановки обрабатывается оставшийся хвост. Пауза распознавания не останавливает запись.")
                        .font(.appFont(size: 16)).foregroundStyle(Color.mutedInk).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func columns<Left: View, Right: View>(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
            left().frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)
            right().frame(maxWidth: .infinity, alignment: .leading)
        }.fixedSize(horizontal: false, vertical: true)
    }
    private func block<Content: View>(_ title: String, _ subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.content) {
            SectionHeading(title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) { content() }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSectionPicker: View {
    @Binding var selection: String
    @FocusState private var focused: String?
    private let sections = ["Запись", "Модель", "Экспорт", "MCP"]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(sections, id: \.self) { item in
                Button { selection = item } label: {
                    screenText(item).font(.appFont(size: 14, weight: selection == item ? .semibold : .medium))
                        .padding(.horizontal, 16).frame(height: 32)
                        .foregroundStyle(Color.ink)
                        .background(selection == item ? Color.paper : .clear, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                        .contentShape(RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                }.shapeAwarePlainButton().focused($focused, equals: item)
                    .accessibilityAddTraits(selection == item ? .isSelected : [])
                    .onMoveCommand { direction in
                        guard direction == .left || direction == .right,
                              let index = sections.firstIndex(of: item) else { return }
                        let next = min(sections.count - 1, max(0, index + (direction == .right ? 1 : -1)))
                        selection = sections[next]; focused = sections[next]
                    }
            }
        }.padding(4).background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain).accessibilityLabel("Раздел настроек")
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
