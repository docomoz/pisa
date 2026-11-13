import SwiftUI

struct SectionHeading: View {
    enum Style {
        case section, dialog, window, page, feature
        var textStyle: PisaDesign.Typography.Style {
            switch self {
            case .section: return PisaDesign.Typography.sectionTitle
            case .dialog: return PisaDesign.Typography.dialogTitle
            case .window: return PisaDesign.Typography.windowTitle
            case .page: return PisaDesign.Typography.pageTitle
            case .feature: return PisaDesign.Typography.footnoteMedium
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
        VStack(alignment: .leading, spacing: style == .feature ? PisaDesign.Spacing.textLine : PisaDesign.Spacing.inline) {
            screenText(title).textStyle(style.textStyle)
            if let subtitle {
                SupportingText(subtitle, style: style == .feature ? PisaDesign.Typography.micro : PisaDesign.Typography.body)
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct SupportingText: View {
    let text: String
    let style: PisaDesign.Typography.Style
    init(_ text: String, style: PisaDesign.Typography.Style = PisaDesign.Typography.body) {
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
        VStack(alignment: .leading, spacing: PisaDesign.Spacing.section) {
            SectionHeading(title, subtitle: message, style: .dialog)
            HStack(spacing: PisaDesign.Spacing.related) {
                screenButton("Отмена", role: .cancel) { dismiss() }
                    .actionButton().focused($cancelFocused)
                    .keyboardShortcut(.cancelAction)
                    .onKeyPress(.return) { dismiss(); return .handled }
                Spacer(minLength: PisaDesign.Spacing.none)
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
        VStack(alignment: .leading, spacing: subtitle == nil ? PisaDesign.Spacing.related : PisaDesign.Spacing.content) {
            SectionHeading(title, subtitle: subtitle)
            VStack(alignment: .leading, spacing: PisaDesign.Spacing.related) { content }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SearchField: View {
    let title: String
    @Binding var text: String
    var compact = false
    var isFocused: Binding<Bool>?

    var body: some View {
        HStack(spacing: PisaDesign.Spacing.inline) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedInk)
            SingleLineTextField(title: title, text: $text, compact: compact, isFocused: isFocused)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .shapeAwarePlainButton(Circle()).screenHelp("Очистить поиск")
            }
        }.textStyle(compact ? PisaDesign.Typography.footnote : PisaDesign.Typography.body)
            .padding(.horizontal, PisaDesign.Spacing.related)
            .padding(.vertical, compact ? PisaDesign.Spacing.related : PisaDesign.Spacing.none)
            .frame(minHeight: compact ? nil : PisaDesign.Metrics.regularHeight)
            .background(compact ? PisaDesign.Colors.paper : PisaDesign.Colors.secondary,
                        in: RoundedRectangle(cornerRadius: compact ? PisaDesign.Metrics.surfaceRadius : PisaDesign.Metrics.cornerRadius))
    }
}

struct FormTextEditor: View {
    @Binding var text: String
    var outlined = false
    var body: some View {
        TextEditor(text: $text).textStyle(PisaDesign.Typography.body)
            .scrollContentBackground(.hidden)
            .frame(height: PisaDesign.Metrics.editorHeight)
            .padding(PisaDesign.Spacing.related)
            .plainSurface(radius: PisaDesign.Metrics.cornerRadius)
            .overlay {
                if outlined {
                    RoundedRectangle(cornerRadius: PisaDesign.Metrics.cornerRadius)
                        .strokeBorder(Color.mutedInk.opacity(0.25), lineWidth: 1).allowsHitTesting(false)
                }
            }
    }
}

struct AlignedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: PisaDesign.Spacing.inline) {
            configuration.icon.frame(width: PisaDesign.Metrics.labelIconWidth, alignment: .leading)
            configuration.title
        }
    }
}

struct Eyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        screenText(title).textStyle(PisaDesign.Typography.overline)
            .foregroundStyle(Color.mutedInk)
    }
}

extension View {
    func dialogContent() -> some View {
        textStyle(PisaDesign.Typography.body).controlSize(.large).actionControls()
            .padding(PisaDesign.Spacing.sheetInset).popupCanvas()
    }
}
