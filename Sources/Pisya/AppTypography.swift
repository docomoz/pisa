import SwiftUI
import AppKit

extension PisyaDesign {
    /// Text roles own size and weight; screens choose a role instead of a point size.
    enum Typography {
        static let hero = Font.system(size: 40, weight: .medium)
        static let pageTitle = Font.system(size: 29, weight: .semibold)
        static let automaticTitle = Font.system(size: 29)
        static let windowTitle = Font.system(size: 26, weight: .semibold)
        static let brand = Font.system(size: 23, weight: .semibold)
        static let dialogTitle = Font.system(size: 22, weight: .semibold)
        static let sectionTitle = Font.system(size: 19, weight: .semibold)
        static let body = Font.system(size: 16)
        static let bodyStrong = Font.system(size: 16, weight: .semibold)
        static let secondary = Font.system(size: 15)
        static let detail = Font.system(size: 14)
        static let detailMedium = Font.system(size: 14, weight: .medium)
        static let detailStrong = Font.system(size: 14, weight: .semibold)
        static let caption = Font.system(size: 13)
        static let captionMedium = Font.system(size: 13, weight: .medium)
        static let footnote = Font.system(size: 12)
        static let footnoteMedium = Font.system(size: 12, weight: .medium)
        static let micro = Font.system(size: 11)
        static let microMedium = Font.system(size: 11, weight: .medium)
        static let overline = Font.system(size: 10, weight: .semibold)
        static let code = Font(NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
        static let elapsed = Font.system(size: 11, design: .monospaced)
        static let button = Font.system(size: 16, weight: .medium)
        static let smallButton = Font.system(size: 13, weight: .medium)
        static let overlineTracking: CGFloat = 1.5
        static let heroTracking: CGFloat = -0.8

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

enum AppTypography {
    // AppKit owns the menu's size, matching the other system menus.
    static let menu = NSFont.menuFont(ofSize: 0)
    static let statusCounter = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    static let credits = NSFont.systemFont(ofSize: 14)
}
