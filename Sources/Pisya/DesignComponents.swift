import SwiftUI

struct SectionHeading: View {
    enum Style {
        case section, dialog, window, page
        var font: Font {
            switch self {
            case .section: return PisyaDesign.Typography.sectionTitle
            case .dialog: return PisyaDesign.Typography.dialogTitle
            case .window: return PisyaDesign.Typography.windowTitle
            case .page: return PisyaDesign.Typography.pageTitle
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
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
            screenText(title).font(style.font)
            if let subtitle { SupportingText(subtitle) }
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct SupportingText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        screenText(text).font(PisyaDesign.Typography.body).foregroundStyle(Color.mutedInk)
            .fixedSize(horizontal: false, vertical: true)
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
    let title: String
    @Binding var text: String
    var compact = false
    var body: some View {
        HStack(spacing: PisyaDesign.Spacing.inline) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.mutedInk)
            TextField(title, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .shapeAwarePlainButton(Circle()).screenHelp("Очистить поиск")
            }
        }.font(compact ? PisyaDesign.Typography.footnote : PisyaDesign.Typography.detail)
            .padding(PisyaDesign.Spacing.related)
            .plainSurface(radius: compact ? PisyaDesign.Metrics.surfaceRadius : PisyaDesign.Metrics.cornerRadius)
    }
}

struct FormTextEditor: View {
    @Binding var text: String
    var outlined = false
    var body: some View {
        TextEditor(text: $text).font(PisyaDesign.Typography.body)
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
            configuration.icon.frame(width: PisyaDesign.Metrics.labelIconWidth)
            configuration.title
        }
    }
}

struct Eyebrow: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        screenText(title).font(PisyaDesign.Typography.overline)
            .tracking(PisyaDesign.Typography.overlineTracking).foregroundStyle(Color.mutedInk)
    }
}

extension View {
    func dialogContent() -> some View {
        font(PisyaDesign.Typography.body).controlSize(.large).actionControls()
            .padding(PisyaDesign.Spacing.sheetInset).popupCanvas()
    }
}
