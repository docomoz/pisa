import SwiftUI

/// All human-readable presentation goes through the same nonbreaking-spacing rules.
/// Editable values, persisted transcripts and copyable code/paths stay verbatim.
func screenText(_ value: String) -> Text { Text(typographicText(value)) }
func screenText(_ value: String, highlighting query: String) -> Text {
    screenText(verbatim: typographicText(value), highlighting: query)
}
func screenText(verbatim value: String, highlighting query: String) -> Text {
    guard !query.isEmpty else { return screenText(verbatim: value) }
    var attributed = AttributedString(value)
    for match in transcriptSearchRanges(in: value, query: query) {
        guard let stringRange = Range(match, in: value),
              let range = Range(stringRange, in: attributed) else { continue }
        attributed.applySearchHighlight(to: range)
    }
    return Text(attributed)
}
func screenText(searchMatch value: String) -> Text {
    var attributed = AttributedString(typographicText(value))
    attributed.applySearchHighlight(to: attributed.startIndex..<attributed.endIndex)
    return Text(attributed)
}

private extension AttributedString {
    mutating func applySearchHighlight(to range: Range<Index>) {
        self[range].backgroundColor = PisaDesign.Colors.searchMatch
        self[range].foregroundColor = Color.ink
    }
}

func screenText(verbatim value: String) -> Text { Text(verbatim: value) }
func screenText(_ date: Date, style: Text.DateStyle) -> Text { Text(date, style: style) }
func screenButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> Button<Text> {
    Button(role: role, action: action) { screenText(title) }
}
func screenLabel(_ title: String, systemImage: String) -> Label<Text, Image> {
    Label { screenText(title) } icon: { Image(systemName: systemImage) }
}
func screenToggle(_ title: String, isOn: Binding<Bool>) -> some View {
    FocusFillToggle(title: title, isOn: isOn)
}

private struct FocusFillToggle: View {
    let title: String
    @Binding var isOn: Bool
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button { isOn.toggle() } label: {
            HStack(spacing: PisaDesign.Spacing.inline) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(isOn ? Color.brandAccent : Color.paper)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(PisaDesign.Typography.Icon.checkmark)
                                .foregroundStyle(Color.white)
                        } else {
                            // This is the checkbox boundary, independent of keyboard focus.
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.mutedInk.opacity(0.65), lineWidth: 1.5)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .opacity(enabled ? 1 : 0.45)
                screenText(title)
                    .foregroundStyle(enabled ? Color.ink : Color.disabledInk)
            }.contentShape(Rectangle())
        }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .focused($focused)
            .background {
                if focused && enabled {
                    RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)
                        .fill(Color.moss.opacity(0.12)).allowsHitTesting(false)
                }
            }
            .focusEffectDisabled()
            .accessibilityRepresentation {
                Toggle(isOn: $isOn) { screenText(title) }.toggleStyle(.checkbox)
            }
    }
}
extension View {
    func screenHelp(_ value: String) -> some View { help(typographicText(value)) }
}
