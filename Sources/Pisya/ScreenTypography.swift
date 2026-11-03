import SwiftUI

/// All human-readable presentation goes through the same nonbreaking-spacing rules.
/// Editable values, persisted transcripts and copyable code/paths stay verbatim.
func screenText(_ value: String) -> Text { Text(typographicText(value)) }
func screenText(verbatim value: String) -> Text { Text(verbatim: value) }
func screenText(_ date: Date, style: Text.DateStyle) -> Text { Text(date, style: style) }
func screenButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> Button<Text> {
    Button(role: role, action: action) { screenText(title) }
}
func screenLabel(_ title: String, systemImage: String) -> Label<Text, Image> {
    Label { screenText(title) } icon: { Image(systemName: systemImage) }
}
func screenToggle(_ title: String, isOn: Binding<Bool>) -> Toggle<Text> {
    Toggle(isOn: isOn) { screenText(title) }
}
func screenMenu<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> Menu<Text, Content> {
    Menu(content: content) { screenText(title) }
}
extension View {
    func screenHelp(_ value: String) -> some View { help(typographicText(value)) }
}
