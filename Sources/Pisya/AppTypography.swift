import SwiftUI
import AppKit

extension PisyaDesign {
    /// A text role always applies its font, leading and tracking together.
    enum Typography {
        struct Style {
            let size: CGFloat
            var weight: Font.Weight = .regular
            var design: Font.Design = .default
            let lineSpacing: CGFloat
            var tracking: CGFloat = 0
        }
        static let hero = Style(size: 40, weight: .medium, lineSpacing: Spacing.hairline, tracking: -0.8)
        static let pageTitle = Style(size: 29, weight: .semibold, lineSpacing: Spacing.compact)
        static let windowTitle = Style(size: 26, weight: .semibold, lineSpacing: Spacing.compact)
        static let brand = Style(size: 23, weight: .semibold, lineSpacing: Spacing.compact)
        static let dialogTitle = Style(size: 22, weight: .semibold, lineSpacing: Spacing.compact)
        static let sectionTitle = Style(size: 19, weight: .semibold, lineSpacing: Spacing.compact)
        static let body = Style(size: 16, lineSpacing: Spacing.textLine)
        static let bodyStrong = Style(size: 16, weight: .semibold, lineSpacing: Spacing.textLine)
        static let secondary = Style(size: 15, lineSpacing: Spacing.textLine)
        static let detail = Style(size: 14, lineSpacing: Spacing.compact)
        static let detailMedium = Style(size: 14, weight: .medium, lineSpacing: Spacing.compact)
        static let detailStrong = Style(size: 14, weight: .semibold, lineSpacing: Spacing.compact)
        static let caption = Style(size: 13, lineSpacing: Spacing.compact)
        static let captionMedium = Style(size: 13, weight: .medium, lineSpacing: Spacing.compact)
        static let footnote = Style(size: 12, lineSpacing: Spacing.compact)
        static let footnoteMedium = Style(size: 12, weight: .medium, lineSpacing: Spacing.compact)
        static let micro = Style(size: 11, lineSpacing: Spacing.hairline)
        static let microMedium = Style(size: 11, weight: .medium, lineSpacing: Spacing.hairline)
        static let overline = Style(size: 10, weight: .semibold, lineSpacing: Spacing.hairline, tracking: 1.5)
        static let transcriptHeading = Style(size: 12, weight: .medium, lineSpacing: Spacing.compact, tracking: 1.5)
        static let code = Style(size: 13, design: .monospaced, lineSpacing: Spacing.compact)
        static let elapsed = Style(size: 11, design: .monospaced, lineSpacing: Spacing.none)
        static let button = Style(size: 16, weight: .medium, lineSpacing: Spacing.none)
        static let smallButton = Style(size: 13, weight: .medium, lineSpacing: Spacing.none)

        enum Icon {
            static let small = Font.system(size: 12)
            static let regular = Font.system(size: 14)
            static let medium = Font.system(size: 18)
            static let close = Font.system(size: 20, weight: .semibold)
            static let featured = Font.system(size: 22, weight: .semibold)
            static let checkmark = Font.system(size: 11, weight: .bold)
            static let disclosure = Font.system(size: 11, weight: .semibold)
            static let emptyState = Font.system(size: 34, weight: .light)
        }
    }
}

enum AppTextSize {
    static let normal = 100
    static let limits = 80...120
    static let step = 10

    static func factor(for percent: Int) -> CGFloat {
        CGFloat(clamp(percent)) / CGFloat(normal)
    }

    static func clamp(_ percent: Int) -> Int {
        min(limits.upperBound, max(limits.lowerBound, percent))
    }
}

extension EnvironmentValues {
    @Entry var appTextScale: CGFloat = 1
}

private struct AppTextStyle: ViewModifier {
    let style: PisyaDesign.Typography.Style
    @Environment(\.appTextScale) private var scale

    func body(content: Content) -> some View {
        content
            .font(.system(size: style.size * scale, weight: style.weight, design: style.design))
            .lineSpacing(style.lineSpacing * scale)
            .tracking(style.tracking * scale)
    }
}

extension View {
    func textStyle(_ style: PisyaDesign.Typography.Style) -> some View {
        modifier(AppTextStyle(style: style))
    }
}

enum AppTypography {
    // AppKit owns the menu's size, matching the other system menus.
    static let menu = NSFont.menuFont(ofSize: 0)
    static let statusCounter = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let credits = NSFont.systemFont(ofSize: 14)
}
