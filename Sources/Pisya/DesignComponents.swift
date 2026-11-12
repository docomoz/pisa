import SwiftUI

struct SectionHeading: View {
    enum Style {
        case section, dialog, window, page, feature
        var textStyle: PisyaDesign.Typography.Style {
            switch self {
            case .section: return PisyaDesign.Typography.sectionTitle
            case .dialog: return PisyaDesign.Typography.dialogTitle
            case .window: return PisyaDesign.Typography.windowTitle
            case .page: return PisyaDesign.Typography.pageTitle
            case .feature: return PisyaDesign.Typography.footnoteMedium
            }
        }
    }
    let title: String
    var subtitle: String?
    var style: Style
    init(_ title: String, subtitle: String? = nil, style: Style = .section) {
        self.title = title; self.subtitle = subtitle; self.style = style
    }
    var body: some View {
        VStack(alignment: .leading, spacing: style == .feature ? PisyaDesign.Spacing.textLine : PisyaDesign.Spacing.inline) {
            screenText(title).textStyle(style.textStyle)
            if let subtitle {
                SupportingText(subtitle, style: style == .feature ? PisyaDesign.Typography.micro : PisyaDesign.Typography.body)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct SupportingText: View {
    let text: String
    let style: PisyaDesign.Typography.Style
    init(_ text: String, style: PisyaDesign.Typography.Style = PisyaDesign.Typography.body) {
        self.text = text; self.style = style
    }
    var body: some View {
        screenText(text).textStyle(style).foregroundStyle(Color.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ConfirmationSheet: View {
    let title: String
    let message: String
    let actionTitle: String
    var role: ButtonRole? = nil
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.section) {
            SectionHeading(title, subtitle: message, style: .dialog)
            HStack(spacing: PisyaDesign.Spacing.related) {
                screenButton("Отмена", role: .cancel) { dismiss() }
                    .actionButton().focused($cancelFocused)
                    .keyboardShortcut(.cancelAction)
                    .onKeyPress(.return) { dismiss(); return .handled }
                Spacer(minLength: PisyaDesign.Spacing.none)
                screenButton(actionTitle, role: role) {
                    dismiss()
                    confirm()
                }.actionButton(role == .destructive ? .recording : .primary)
            }
        }.dialogContent().frame(width: 480)
            .defaultFocus($cancelFocused, true)
    }
}

struct FormSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: subtitle == nil ? PisyaDesign.Spacing.related : PisyaDesign.Spacing.content) {
            SectionHeading(title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: PisyaDesign.Spacing.related) { content }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchField: View {
    @Environment(\.appTextScale) private var textScale
    @State private var isEditing = false
    let title: String
    @Binding var text: String
    var compact = false
    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.inline) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedInk)
            TextField(title, text: $text, onEditingChanged: { isEditing = $0 })
                .textFieldStyle(.plain)
                // At the largest text size the native field editor sits one point higher.
                .offset(y: textScale >= 1.2 && isEditing ? 1 : 0)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .shapeAwarePlainButton(Circle()).screenHelp("Очистить поиск")
            }
        }.textStyle(compact ? PisyaDesign.Typography.footnote : PisyaDesign.Typography.body)
            .padding(.horizontal, PisyaDesign.Spacing.related)
            .padding(.vertical, compact ? PisyaDesign.Spacing.related : PisyaDesign.Spacing.none)
            .frame(minHeight: compact ? nil : PisyaDesign.Metrics.regularHeight)
            .background(compact ? PisyaDesign.Colors.paper : PisyaDesign.Colors.secondary,
                        in: RoundedRectangle(cornerRadius: compact ? PisyaDesign.Metrics.surfaceRadius : PisyaDesign.Metrics.cornerRadius))
    }
}

struct FormTextEditor: View {
    @Binding var text: String
    var outlined = false
    var body: some View {
        TextEditor(text: $text).textStyle(PisyaDesign.Typography.body)
            .scrollContentBackground(.hidden)
            .frame(height: PisyaDesign.Metrics.editorHeight)
            .padding(PisyaDesign.Spacing.related)
            .plainSurface(radius: PisyaDesign.Metrics.cornerRadius)
            .overlay {
                if outlined {
                    RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)
                        .strokeBorder(Color.mutedInk.opacity(0.25), lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}

struct AlignedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: PisyaDesign.Spacing.inline) {
            configuration.icon.frame(width: PisyaDesign.Metrics.labelIconWidth, alignment: .leading)
            configuration.title
        }
    }
}

struct Eyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        screenText(title).textStyle(PisyaDesign.Typography.overline)
            .foregroundStyle(Color.mutedInk)
    }
}

extension View {
    func dialogContent() -> some View {
        textStyle(PisyaDesign.Typography.body).controlSize(.large).actionControls()
            .padding(PisyaDesign.Spacing.sheetInset).popupCanvas()
    }
}
