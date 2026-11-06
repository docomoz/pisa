import SwiftUI
import AppKit
struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) var dismiss
    @State private var section = "Запись"
    @State private var showRecordingDetails = false
    init(initialSection: String = "Запись") {
        _section = State(initialValue: initialSection)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            HStack(spacing: PisyaDesign.Spacing.inline) { SectionHeading("Настройки", style: .window); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(PisyaDesign.Typography.Icon.close).foregroundStyle(Color.mutedInk) }.shapeAwarePlainButton(Circle()).screenHelp("Закрыть настройки").accessibilityLabel("Закрыть настройки") }
            SettingsSectionPicker(selection: $section)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                    switch section {
                    case "Запись":
                        recordingSettings
                    case "Модель":
                        columns {
                        block("Qwen3-ASR", "Локальное распознавание русской речи на Apple Silicon") {
                            screenToggle("Тихая обработка", isOn: Binding(get: { state.preferences.usesQuietProcessing }, set: { state.preferences.quietProcessing = $0; state.savePreferences() }))
                            SupportingText("Меньше параллельной нагрузки и паузы между фрагментами. Расшифровка займёт больше времени.")
                            screenLabel(state.modelReady ? "Модель готова" : "Модели ещё не установлены", systemImage: state.modelReady ? "checkmark.circle.fill" : "externaldrive").foregroundStyle(Color.moss)
                            if let url = state.modelURL() { screenText(verbatim: url.path).textStyle(PisyaDesign.Typography.code).fixedSize(horizontal: false, vertical: true).foregroundStyle(Color.mutedInk).textSelection(.enabled) }
                            screenButton("Выбрать папку модели…") { state.chooseModel() }.actionButton()
                            screenButton(state.modelReady ? "Проверить и установить модели" : "Загрузить модели") {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { state.modelSetup.check(); state.modelSetup.presented = true }
                            }.actionButton()
                            SupportingText("Pisya загрузит проверенные модели речи и участников с Hugging Face — около 3 ГБ. Распознавание выполняется на Mac. Также можно выбрать свою папку MLX-модели Qwen3-ASR.")
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        block("Словарь распознавания", "Чтобы Pisya точнее записывала имена и названия в вашей речи и речи собеседников") {
                            SupportingText("Например, добавьте «2ГИС», если вместо него получается «два гис»")
                            FormTextEditor(text: $state.preferences.vocabulary, outlined: true)
                                .accessibilityLabel("Словарь распознавания")
                                .accessibilityHint("Введите слова через запятую или с новой строки")
                                .onChange(of: state.preferences.vocabulary) { state.savePreferences() }
                            SupportingText("Укажите нужное написание слов через запятую или с новой строки. Можно оставить поле пустым.")
                        }


                            }
                        }
                    case "Голоса":
                        SavedVoicesSettings(scrollTo: { id in proxy.scrollTo(id) })
                    case "Экспорт":
                        columns {
                        block("Папка для расшифровок", "Markdown — для обычной папки, Dropbox или Obsidian") {
                            if let path = state.preferences.exportDisplayPath { screenText(verbatim: path).textStyle(PisyaDesign.Typography.code).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } else { screenText("Автоэкспорт выключен").foregroundStyle(Color.mutedInk) }
                            HStack(spacing: PisyaDesign.Spacing.related) { screenButton("Выбрать папку…") { state.chooseExportFolder() }.actionButton(); if state.preferences.exportBookmark != nil { screenButton("Отключить") { state.preferences.exportBookmark = nil; state.preferences.exportDisplayPath = nil; state.savePreferences() }.actionButton() } }
                            SupportingText("После расшифровки и последующих правок файл обновляется автоматически. В него входят текст, участники и временные метки. Аудио остаётся в библиотеке.")
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        block("Если папка синхронизируется", "Dropbox, iCloud или другой сервис могут отправлять её содержимое в облако") { SupportingText("Выбор такой папки разрешает выгрузку текстов через приложение синхронизации. Это отдельно от локального распознавания.") }

                            }
                        }
                    default:
                        columns {
                        block("Доступ к встречам через MCP", "Локальный сервер даёт доступ только для чтения и работает без сетевого порта") {
                            screenToggle("Разрешить MCP читать библиотеку", isOn: $state.preferences.mcpEnabled).onChange(of: state.preferences.mcpEnabled) { state.savePreferences() }
                            SupportingText("Подключённый клиент сможет находить реплики с контекстом и читать расшифровки. Ссылки на источники открывают нужный фрагмент в Pisya. Если клиент использует облачную модель, прочитанный текст может уйти к ней. Аудиофайлы и изменение библиотеки через MCP недоступны.")
                        }
                        } right: {
                            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                        block("Подключение", "Добавьте этот локальный сервер в настройки вашего клиента:") {
                            screenText(verbatim: "[mcp_servers.pisya]\ncommand = \"\(state.mcpPath)\"")
                                .textStyle(PisyaDesign.Typography.code)
                                .foregroundStyle(PisyaDesign.Colors.paper)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(PisyaDesign.Spacing.content)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(PisyaDesign.Colors.ink, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
                            screenButton("Скопировать конфигурацию") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString("[mcp_servers.pisya]\ncommand = \"\(state.mcpPath)\"", forType: .string) }.actionButton()
                            SupportingText("Доступны встречи, папки, поиск реплик и сведения о полноте расшифровки. Выключатель отзывает доступ и у уже запущенного клиента.")
                        }
                            }
                            .disabled(!state.preferences.mcpEnabled)
                            .opacity(state.preferences.mcpEnabled ? 1 : 0.45)
                        }

                    }
                }.padding(.vertical, PisyaDesign.Spacing.compact)
            }.id(section)
            }
            HStack(spacing: PisyaDesign.Spacing.inline) {
                Image(nsImage: BrandMark.headerIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                screenText("Pisya \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                    .textStyle(PisyaDesign.Typography.footnote)
                    .foregroundStyle(Color.mutedInk)
                Spacer()
                screenButton("Готово") { dismiss() }.actionButton(.primary).keyboardShortcut(.cancelAction)
            }
        }.dialogContent().frame(width: 900, height: 700)
            .background(SettingsInitialFocus().allowsHitTesting(false))
            .background(ClickToUnfocus())
    }
    private var recordingSettings: some View {
        HStack(alignment: .top, spacing: PisyaDesign.Spacing.section) {
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                block("Источники звука", "Микрофон и системный звук") {
                    SupportingText("Начните запись заранее, затем откройте встречу в любом приложении или браузере. Записываются и другие звуки Mac.")
                }
                block("Автозапись", "Экспериментальная функция") {
                    screenToggle("Автоматический старт и стоп", isOn: Binding(get: { state.preferences.automaticRecording }, set: { state.setAutomatic($0) }))
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        screenLabel("Старт — через 3 секунды", systemImage: "record.circle")
                        screenLabel("Стоп — через 45 секунд без микрофона", systemImage: "stop.circle").fixedSize(horizontal: false, vertical: true)
                    }.textStyle(PisyaDesign.Typography.body).fixedSize(horizontal: false, vertical: true)
                    SupportingText("Ориентируется на использование микрофона другими приложениями, а не на громкость звука.")
                    // Keep the disclosure and its text together so the block's row spacing
                    // cannot add a second gap between the heading and its content.
                    VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
                        Button { showRecordingDetails.toggle() } label: {
                            HStack(spacing: PisyaDesign.Spacing.inline) {
                                Image(systemName: showRecordingDetails ? "chevron.down" : "chevron.right").font(PisyaDesign.Typography.Icon.disclosure).frame(width: 12)
                                screenText("Как работает и ограничения")
                                Spacer(minLength: 0)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.shapeAwarePlainButton().foregroundStyle(Color.moss)
                            .accessibilityValue(showRecordingDetails ? "Развёрнуто" : "Свёрнуто")
                        if showRecordingDetails {
                            SupportingText("Диктовка и тест микрофона тоже могут запустить запись. Звонки без доступа к микрофону не определяются. Отключение микрофона в приложении может вызвать автостоп. Если вы начали запись вручную до встречи, автостоп включится только после обнаружения звонка.")
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.black.opacity(0.08)).frame(width: 1)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
                block("Разрешения macOS", "Нужны для записи вашего голоса и собеседников") {
                    Button { NSWorkspace.shared.open(CapturePermission.microphone.settingsURL) } label: { screenLabel("Микрофон", systemImage: "mic") }.actionButton()
                    Button { NSWorkspace.shared.open(CapturePermission.systemAudio.settingsURL) } label: { screenLabel("Системный звук", systemImage: "speaker.wave.2") }.actionButton()
                }.labelStyle(AlignedIconLabelStyle())
                block("Фоновая расшифровка", "Черновик во время звонка") {
                    screenToggle("Расшифровывать во время записи", isOn: Binding(get: { state.preferences.usesBackgroundTranscription }, set: { state.setBackgroundTranscription($0) }))
                    SupportingText("После остановки обрабатывается оставшийся хвост. Пауза распознавания не останавливает запись.")
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
        FormSection(title, subtitle: subtitle, content: content)
    }
}

private struct SettingsSectionPicker: View {
    @Binding var selection: String
    @FocusState private var focused: String?
    private let sections = ["Запись", "Модель", "Голоса", "Экспорт", "MCP"]
    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.compact) {
            ForEach(sections, id: \.self) { item in
                Button { selection = item } label: {
                    screenText(item).textStyle(selection == item ? PisyaDesign.Typography.detailStrong : PisyaDesign.Typography.detailMedium)
                        .padding(.horizontal, PisyaDesign.Spacing.content).frame(height: 32)
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
        }.padding(PisyaDesign.Spacing.compact).background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.surfaceRadius))
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
