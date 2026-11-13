import SwiftUI

struct MeetingPhraseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phrase = ""
    @FocusState private var refreshFocused: Bool
    let nextPhrase: () -> String

    var body: some View {
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            SectionHeading("Фраза для созвона", subtitle: "Если созвон заканчивается раньше времени, скажите эту фразу и займитесь своими делами на 10 минут", style: .dialog)
            HStack(alignment: .top, spacing: PisaDesign.Spacing.content) {
                Text("🤦")
                    .font(PisaDesign.Typography.Icon.featured)
                    .accessibilityHidden(true)
                ScrollView {
                    screenText(phrase)
                        .textStyle(PisaDesign.Typography.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 104, maxHeight: 220, alignment: .topLeading)
            }
            .padding(PisaDesign.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plainSurface()
            .overlay {
                RoundedRectangle(cornerRadius: PisaDesign.Metrics.surfaceRadius)
                    .strokeBorder(Color.mutedInk.opacity(0.15), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            HStack(spacing: PisaDesign.Spacing.related) {
                screenButton("Закрыть") { dismiss() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: PisaDesign.Spacing.none)
                Button { refresh() } label: {
                    screenLabel("Другая фраза", systemImage: "arrow.clockwise")
                }
                .actionButton(.primary)
                .focused($refreshFocused)
                .keyboardShortcut(.defaultAction)
            }
        }
        .dialogContent()
        .frame(width: 620)
        .defaultFocus($refreshFocused, true)
        .onAppear { refresh() }
    }

    private func refresh() {
        phrase = nextPhrase()
    }
}
