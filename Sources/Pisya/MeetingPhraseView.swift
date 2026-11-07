import SwiftUI

struct MeetingPhraseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var generator = MeetingPhraseGenerator()
    @State private var phrase = ""
    @FocusState private var refreshFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading("Фраза для созвона", style: .dialog)
            ScrollView {
                screenText(phrase)
                    .textStyle(PisyaDesign.Typography.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 80, maxHeight: 240, alignment: .topLeading)
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
        .frame(width: 480)
        .defaultFocus($refreshFocused, true)
        .onAppear { refresh() }
    }

    private func refresh() {
        phrase = generator.next()
    }
}
