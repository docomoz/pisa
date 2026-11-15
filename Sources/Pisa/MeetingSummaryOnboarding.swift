import SwiftUI
import AppKit

struct MeetingSummaryOnboarding: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var saveError: String?

    private var configuration: String {
        MCPClientConfiguration.toml(commandPath: state.mcpPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            HStack(alignment: .top, spacing: PisaDesign.Spacing.inline) {
                SectionHeading("Саммари встречи — у вашего AI-ассистента", style: .dialog)
                Spacer(minLength: PisaDesign.Spacing.none)
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(PisaDesign.Typography.Icon.close)
                        .foregroundStyle(Color.mutedInk)
                }
                .shapeAwarePlainButton(Circle())
                .screenHelp("Закрыть")
                .accessibilityLabel("Закрыть")
                .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
                    SupportingText("Pisa сознательно не делает саммари: она записывает и расшифровывает встречи, а их осмысление оставляет вашему настроенному AI-ассистенту. Он знает ваши задачи и лучше подстроит результат под вас — будь это Claude, ChatGPT, Hermes, BB или другой ассистент на выбранной вами локальной или облачной модели.")

                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                        SectionHeading("Подключите встречи один раз")
                        SupportingText("Сделайте скриншот этих настроек и попросите своего AI-ассистента: «Настрой подключение к MCP-серверу Pisa». MCP даёт ассистенту доступ к расшифровкам. Для подключения нужен клиент с поддержкой локальных MCP-серверов (stdio).")
                    }

                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                        screenToggle("Разрешить MCP читать библиотеку", isOn: Binding(
                            get: { state.preferences.mcpEnabled },
                            set: { setMCPEnabled($0) }
                        ))
                        screenText("Локальный MCP-сервер · stdio")
                            .textStyle(PisaDesign.Typography.detailStrong)
                        screenText(verbatim: configuration)
                            .textStyle(PisaDesign.Typography.code)
                            .foregroundStyle(PisaDesign.Colors.paper)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .padding(PisaDesign.Spacing.content)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(PisaDesign.Colors.ink, in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                        screenButton("Скопировать конфигурацию") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(configuration, forType: .string)
                        }.actionButton()
                        SupportingText(state.preferences.mcpEnabled
                            ? "Ассистент сможет читать и искать встречи. Менять библиотеку и получать аудиофайлы через MCP нельзя. При выборе облачной модели прочитанный текст может отправляться ей."
                            : "Доступ выключен. Включите его здесь, чтобы ассистент мог читать и искать встречи.",
                            style: PisaDesign.Typography.detail)
                    }

                    VStack(alignment: .leading, spacing: PisaDesign.Spacing.inline) {
                        SectionHeading("Дальше просто спрашивайте")
                        SupportingText("Попросите ассистента: «Сделай саммари последней встречи», «О чём мы договорились?» или «Какие задачи остались за мной?». Можно задавать любые вопросы по прошедшим встречам. Настройки подключения всегда доступны в Pisa: Настройки → MCP.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: PisaDesign.Spacing.section) {
                SupportingText(saveError ?? "«Я понял» скроет кнопку во всех расшифровках", style: PisaDesign.Typography.detail)
                Spacer(minLength: PisaDesign.Spacing.none)
                screenButton("Я понял") { acknowledge() }
                    .actionButton(.primary)
                    .fixedSize()
            }
        }
        .dialogContent()
        .frame(width: 720, height: 640)
    }

    private func acknowledge() {
        var preferences = state.preferences
        preferences.summaryOnboardingAcknowledged = true
        do {
            try state.library.savePreferences(preferences)
            state.preferences = preferences
            dismiss()
        } catch {
            saveError = "Не удалось сохранить подтверждение. Попробуйте ещё раз."
        }
    }

    private func setMCPEnabled(_ enabled: Bool) {
        var preferences = state.preferences
        preferences.mcpEnabled = enabled
        do {
            try state.library.savePreferences(preferences)
            state.preferences = preferences
            Analytics.setting(.mcp, enabled: enabled)
            saveError = nil
        } catch {
            saveError = "Не удалось изменить доступ к библиотеке. Попробуйте ещё раз."
        }
    }
}
