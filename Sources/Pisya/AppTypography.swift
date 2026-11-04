import SwiftUI
import AppKit

extension PisyaDesign {
    /// A text role always applies its font, leading and tracking together.
    enum Typography {
        struct Style {
            let font: Font
            let lineSpacing: CGFloat
            var tracking: CGFloat = 0
        }
        static let hero = Style(font: .system(size: 40, weight: .medium), lineSpacing: Spacing.hairline, tracking: -0.8)
        static let pageTitle = Style(font: .system(size: 29, weight: .semibold), lineSpacing: Spacing.compact)
        static let automaticTitle = Style(font: .system(size: 29), lineSpacing: Spacing.compact)
        static let windowTitle = Style(font: .system(size: 26, weight: .semibold), lineSpacing: Spacing.compact)
        static let brand = Style(font: .system(size: 23, weight: .semibold), lineSpacing: Spacing.compact)
        static let dialogTitle = Style(font: .system(size: 22, weight: .semibold), lineSpacing: Spacing.compact)
        static let sectionTitle = Style(font: .system(size: 19, weight: .semibold), lineSpacing: Spacing.compact)
        static let body = Style(font: .system(size: 16), lineSpacing: Spacing.textLine)
        static let bodyStrong = Style(font: .system(size: 16, weight: .semibold), lineSpacing: Spacing.textLine)
        static let secondary = Style(font: .system(size: 15), lineSpacing: Spacing.textLine)
        static let detail = Style(font: .system(size: 14), lineSpacing: Spacing.compact)
        static let detailMedium = Style(font: .system(size: 14, weight: .medium), lineSpacing: Spacing.compact)
        static let detailStrong = Style(font: .system(size: 14, weight: .semibold), lineSpacing: Spacing.compact)
        static let caption = Style(font: .system(size: 13), lineSpacing: Spacing.compact)
        static let captionMedium = Style(font: .system(size: 13, weight: .medium), lineSpacing: Spacing.compact)
        static let footnote = Style(font: .system(size: 12), lineSpacing: Spacing.compact)
        static let footnoteMedium = Style(font: .system(size: 12, weight: .medium), lineSpacing: Spacing.compact)
        static let micro = Style(font: .system(size: 11), lineSpacing: Spacing.hairline)
        static let microMedium = Style(font: .system(size: 11, weight: .medium), lineSpacing: Spacing.hairline)
        static let overline = Style(font: .system(size: 10, weight: .semibold), lineSpacing: Spacing.hairline, tracking: 1.5)
        static let transcriptHeading = Style(font: .system(size: 12, weight: .medium), lineSpacing: Spacing.compact, tracking: 1.5)
        static let code = Style(font: Font(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)), lineSpacing: Spacing.compact)
        static let elapsed = Style(font: .system(size: 11, design: .monospaced), lineSpacing: Spacing.none)
        static let button = Style(font: .system(size: 16, weight: .medium), lineSpacing: Spacing.none)
        static let smallButton = Style(font: .system(size: 13, weight: .medium), lineSpacing: Spacing.none)

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

extension View {
    func textStyle(_ style: PisyaDesign.Typography.Style) -> some View {
        font(style.font).lineSpacing(style.lineSpacing).tracking(style.tracking)
    }
}

enum AppTypography {
    // AppKit owns the menu's size, matching the other system menus.
    static let menu = NSFont.menuFont(ofSize: 0)
    static let statusCounter = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let credits = NSFont.systemFont(ofSize: 14)
}
