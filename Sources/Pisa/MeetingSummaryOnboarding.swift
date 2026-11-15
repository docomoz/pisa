import SwiftUI
import AppKit

struct MeetingSummaryOnboarding: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTextScale) private var textScale
    @State private var saveError: String?

    private var configuration: String {
        MCPClientConfiguration.toml(commandPath: state.mcpPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
            HStack(alignment: .top, spacing: PisaDesign.Spacing.inline) {
                SectionHeading("Саммари встречи — у вашего AI‑ассистента", style: .dialog)
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
            ViewThatFits(in: .vertical) {
                instructions.fixedSize(horizontal: false, vertical: true)
                ScrollView { instructions }
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
        .frame(width: 750 * max(1, textScale))
        .frame(maxHeight: 640)
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
            SupportingText("Pisa расшифровывает встречи и сознательно оставляет саммари вашему AI‑ассистенту. Ассистент знает, над чем вы работаете, и выделит главное для текущих задач. Claude, ChatGPT, Hermes, BB или другой — на локальной или облачной модели по вашему\u{00a0}выбору.")

            SectionHeading("Подключите Pisa к ассистенту", subtitle: "Сделайте скриншот настроек ниже и попросите своего AI‑ассистента подключить MCP‑сервер Pisa. Нужна поддержка локального MCP (stdio).")

            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) {
                HStack(spacing: PisaDesign.Spacing.related) {
                    screenToggle("Разрешить MCP читать библиотеку", isOn: Binding(
                        get: { state.preferences.mcpEnabled },
                        set: { setMCPEnabled($0) }
                    ))
                    Spacer(minLength: PisaDesign.Spacing.none)
                    screenButton("Скопировать настройки") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(configuration, forType: .string)
                    }.actionButton()
                        .fixedSize()
                }
                screenText(verbatim: configuration)
                    .textStyle(PisaDesign.Typography.code)
                    .foregroundStyle(PisaDesign.Colors.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(PisaDesign.Spacing.related)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PisaDesign.Colors.ink, in: RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius))
                if !state.preferences.mcpEnabled {
                    SupportingText("Включите доступ, чтобы ассистент мог читать встречи", style: PisaDesign.Typography.detail)
                }
            }

            SupportingText("После подключения просите саммари любой встречи и уточняйте детали\u{00a0}— о чём договорились, кто за что отвечает и что осталось сделать. Можно задавать вопросы сразу по нескольким встречам или делать саммари по итогу дня.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
