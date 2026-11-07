import SwiftUI

struct MeetingPhraseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var generator = MeetingPhraseGenerator()
    @State private var phrase = ""
    @FocusState private var refreshFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Фраза для созвона", subtitle: "Если созвон заканчивается раньше времени, скажите эту фразу и отключайтесь на 10 минут — коллегам будет что обсудить", style: .dialog)
            HStack(alignment: .top, spacing: PisyaDesign.Spacing.content) {
                Text("🤦")
                    .font(PisyaDesign.Typography.Icon.emptyState)
                    .accessibilityHidden(true)
                ScrollView {
                    screenText(phrase)
                        .textStyle(PisyaDesign.Typography.sectionTitle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(minHeight: 140, maxHeight: 260, alignment: .topLeading)
            }
            .padding(PisyaDesign.Spacing.section)
            .frame(maxWidth: .infinity, alignment: .leading)
            .plainSurface()
            .overlay {
                RoundedRectangle(cornerRadius: PisyaDesign.Metrics.surfaceRadius)
                    .strokeBorder(Color.mutedInk.opacity(0.15), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Закрыть") { dismiss() }
                    .actionButton()
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: PisyaDesign.Spacing.none)
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
        phrase = generator.next()
    }
}
