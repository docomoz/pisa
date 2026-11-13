import SwiftUI
import AppKit

enum PisyaDesign {
    enum Colors {
        // Bronegis light-theme OKLCH tokens converted to sRGB.
        static let ink = Color(red: 0.08727, green: 0.09624, blue: 0.10585)
        static let actionInk = Color(red: 0.13376, green: 0.45195, blue: 0.13214)
        static let brandAccent = Color(red: 0.26624, green: 0.72562, blue: 0.26006)
        static let brandAccentInk = Color.white
        static let primaryHover = Color(red: 0.21844, green: 0.65153, blue: 0.21485)
        static let primaryPressed = Color(red: 0.18, green: 0.59, blue: 0.18)
        static let secondary = Color(red: 0.95243, green: 0.95896, blue: 0.96604)
        static let secondaryAction = Color(red: 0.90, green: 0.92, blue: 0.94)
        static let secondaryHover = Color(red: 0.86, green: 0.89, blue: 0.92)
        static let secondaryPressed = Color(red: 0.80, green: 0.84, blue: 0.88)
        static let recording = Color(red: 0.74508, green: 0.13808, blue: 0.13777)
        static let recordingHover = Color(red: 0.68, green: 0.11, blue: 0.11)
        static let recordingPressed = Color(red: 0.60, green: 0.09, blue: 0.09)
        static let disabledInk = Color(white: 0.42)
        static let disabledSurface = Color(white: 0.97)
        static let paper = Color.white
        static let mutedInk = Color(red: 0.25091, green: 0.26128, blue: 0.27245)
        static let sidebar = Color(red: 0.93417, green: 0.94068, blue: 0.94773)
        static let selection = Color(white: 0.84)
        static let searchMatch = Color(red: 1, green: 0.90, blue: 0.50)
    }
    enum Metrics {
        static let cornerRadius: CGFloat = 8
        static let regularHeight: CGFloat = 36
        static let smallHeight: CGFloat = 32
        static let surfaceRadius: CGFloat = 12
        static let selectionRadius: CGFloat = 10
        static let navigationRadius: CGFloat = 9
        static let editorHeight: CGFloat = 180
        static let labelIconWidth: CGFloat = 24
        static let elapsedWidth: CGFloat = 58
        static let elapsedHeight: CGFloat = 15
        static let progressHeight: CGFloat = 10
        static let progressValueWidth: CGFloat = 46
    }
    enum Spacing {
        static let none: CGFloat = 0
        static let hairline: CGFloat = 2
        static let compact: CGFloat = 4
        static let menuItemInset: CGFloat = 5
        static let textLine: CGFloat = 7
        static let inline: CGFloat = 8
        static let related: CGFloat = 12
        static let content: CGFloat = 16
        static let section: CGFloat = 24
        static let sheetInset: CGFloat = 28
        static let page: CGFloat = 32
    }
}


extension Color {
    static let ink = PisyaDesign.Colors.ink
    static let moss = PisyaDesign.Colors.actionInk
    static let brandAccent = PisyaDesign.Colors.brandAccent
    static let actionTint = PisyaDesign.Colors.secondary
    static let recordingRed = PisyaDesign.Colors.recording
    static let disabledInk = PisyaDesign.Colors.disabledInk
    static let disabledTint = PisyaDesign.Colors.disabledSurface
    static let paper = PisyaDesign.Colors.paper
    static let sidebarTint = PisyaDesign.Colors.sidebar
    static let selectionTint = PisyaDesign.Colors.selection
    static let mutedInk = PisyaDesign.Colors.mutedInk
}

enum ActionButtonRole { case primary, secondary, recording }
enum ActionButtonSize { case small, regular }

extension View {
    func popupCanvas() -> some View {
        foregroundStyle(Color.ink).tint(Color.brandAccent).background(Color.paper)
            .background(SlimScrollbars().allowsHitTesting(false))
            .focusEffectDisabled()
    }
    func plainSurface(radius: CGFloat = PisyaDesign.Metrics.surfaceRadius) -> some View {
        background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: radius))
    }
    func plainSelection(_ selected: Bool, radius: CGFloat = PisyaDesign.Metrics.selectionRadius) -> some View {
        background {
            if selected {
                RoundedRectangle(cornerRadius: radius).fill(Color.selectionTint)
                    .allowsHitTesting(false)
            }
        }
    }
    func actionControls() -> some View { buttonStyle(ActionButtonStyle()).focusEffectDisabled() }
    func actionButton(_ role: ActionButtonRole = .secondary, size: ActionButtonSize = .regular) -> some View {
        buttonStyle(ActionButtonStyle(role: role, size: size))
            .controlKeyboardFocus()
    }
    func speakerChip() -> some View { actionButton(.secondary, size: .small) }
    func shapeAwarePlainButton<Outline: Shape>(_ shape: Outline = RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)) -> some View {
        buttonStyle(PlainControlStyle()).controlKeyboardFocus()
    }
    func controlKeyboardFocus() -> some View { modifier(ControlKeyboardFocus()) }
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

private struct PointingHandCursor: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovered = inside
                updateCursor()
            }
            .onChange(of: enabled) { updateCursor() }
            .onDisappear {
                if hovered && NSCursor.current == NSCursor.pointingHand { NSCursor.arrow.set() }
            }
    }

    private func updateCursor() {
        if hovered && enabled { NSCursor.pointingHand.set() }
        else if NSCursor.current == NSCursor.pointingHand { NSCursor.arrow.set() }
    }
}

private struct ControlFocusedKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    @Entry var showsControlKeyboardFocus = true

    var controlFocused: Bool {
        get { self[ControlFocusedKey.self] }
        set { self[ControlFocusedKey.self] = newValue }
    }
}
private struct ControlKeyboardFocus: ViewModifier {
    // Bind the control itself: macOS doesn't propagate its focus into a ButtonStyle label.
    @FocusState private var focused: Bool
    @Environment(\.showsControlKeyboardFocus) private var showsFocus
    func body(content: Content) -> some View {
        content.focused($focused)
            .environment(\.controlFocused, focused && showsFocus)
            .focusEffectDisabled()
    }
}

private struct ActionButtonStyle: ButtonStyle {
    var role: ActionButtonRole = .secondary
    var size: ActionButtonSize = .regular
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        ActionButtonContent(label: configuration.label, role: role, size: size,
                            enabled: enabled, pressed: configuration.isPressed)
    }
}

private struct ActionButtonContent<Label: View>: View {
    let label: Label
    let role: ActionButtonRole
    let size: ActionButtonSize
    let enabled: Bool
    let pressed: Bool
    @State private var hovered = false
    @Environment(\.controlFocused) private var focused
    private var background: Color {
        guard enabled else { return PisyaDesign.Colors.disabledSurface }
        switch role {
        case .primary:
            return pressed ? PisyaDesign.Colors.primaryPressed : (hovered || focused) ? PisyaDesign.Colors.primaryHover : PisyaDesign.Colors.brandAccent
        case .secondary:
            return (pressed || focused) ? PisyaDesign.Colors.secondaryPressed : hovered ? PisyaDesign.Colors.secondaryHover : PisyaDesign.Colors.secondaryAction
        case .recording:
            return pressed ? PisyaDesign.Colors.recordingPressed : (hovered || focused) ? PisyaDesign.Colors.recordingHover : PisyaDesign.Colors.recording
        }
    }
    private var foreground: Color {
        guard enabled else { return PisyaDesign.Colors.disabledInk }
        switch role {
        case .primary: return PisyaDesign.Colors.brandAccentInk
        case .secondary: return PisyaDesign.Colors.ink
        case .recording: return .white
        }
    }
    var body: some View {
        label
            .textStyle(size == .small ? PisyaDesign.Typography.smallButton : PisyaDesign.Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .small ? PisyaDesign.Spacing.related : PisyaDesign.Spacing.content)
            .frame(minHeight: size == .small ? PisyaDesign.Metrics.smallHeight : PisyaDesign.Metrics.regularHeight)
            .background(background, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
            .focusEffectDisabled()
            .onHover { hovered = $0 }
            .pointingHandCursor()
    }
}

struct FormTextField: View {
    @Environment(\.isEnabled) private var enabled
    let title: String
    @Binding var text: String
    var isFocused: Binding<Bool>?
    var accessibilityTitle: String?
    var onSubmit: (() -> Void)?
    var onCommand: ((Selector) -> Bool)?

    var body: some View {
        SingleLineTextField(title: title, text: $text, isFocused: isFocused, accessibilityTitle: accessibilityTitle,
                            onSubmit: onSubmit, onCommand: onCommand)
            .padding(.horizontal, PisyaDesign.Spacing.related)
            .frame(minHeight: PisyaDesign.Metrics.regularHeight)
            .background(enabled ? PisyaDesign.Colors.secondary : PisyaDesign.Colors.disabledSurface,
                        in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
    }
}

/// A borderless AppKit field uses the same text inset for its cell and its
/// field editor. SwiftUI's plain field can round those baselines differently.
struct SingleLineTextField: NSViewRepresentable {
    @Environment(\.appTextScale) private var scale
    @Environment(\.isEnabled) private var enabled
    let title: String
    @Binding var text: String
    var compact = false
    var isFocused: Binding<Bool>?
    var accessibilityTitle: String?
    var onSubmit: (() -> Void)?
    var onCommand: ((Selector) -> Bool)?

    func makeNSView(context: Context) -> NSTextField {
        let field = StationaryPlaceholderField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.field = self
        field.isEnabled = enabled
        field.font = AppTypography.singleLineField(scale: scale, compact: compact)
        field.textColor = NSColor(enabled ? Color.ink : Color.disabledInk)
        let placeholder = typographicText(title)
        // Draw the same placeholder under the transparent field editor, since
        // macOS 15 hides the standard placeholder as soon as editing starts.
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: field.font ?? AppTypography.singleLineField(scale: scale, compact: compact),
            .foregroundColor: NSColor.clear,
        ])
        field.needsDisplay = true
        field.setAccessibilityLabel(typographicText(accessibilityTitle ?? title))

        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != text && !editor.hasMarkedText() {
                let insertion = min(editor.selectedRange().location, (text as NSString).length)
                editor.string = text
                editor.setSelectedRange(NSRange(location: insertion, length: 0))
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }

        let requestedFocus = isFocused?.wrappedValue
        guard coordinator.requestedFocus != requestedFocus else { return }
        coordinator.requestedFocus = requestedFocus
        guard let requestedFocus else { return }
        // An initial request can arrive before SwiftUI attaches the field.
        DispatchQueue.main.async { [weak field, weak coordinator] in
            guard let field, let coordinator, coordinator.requestedFocus == requestedFocus,
                  let window = field.window else { return }
            if requestedFocus && field.isEnabled && field.currentEditor() == nil {
                field.selectText(nil)
            } else if !requestedFocus, let editor = field.currentEditor(), window.firstResponder === editor {
                window.makeFirstResponder(nil)
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var field: SingleLineTextField
        var requestedFocus: Bool?

        init(field: SingleLineTextField) { self.field = field }

        func controlTextDidBeginEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.needsDisplay = true
            reportFocus(true)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            (notification.object as? NSTextField)?.needsDisplay = true
            reportFocus(false)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            (notification.object as? NSTextField)?.needsDisplay = true
            reportFocus(true)
            if field.text != editor.string { field.text = editor.string }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if field.onCommand?(command) == true { return true }
            guard command == #selector(NSResponder.insertNewline(_:)), let submit = field.onSubmit else { return false }
            submit()
            return true
        }

        private func reportFocus(_ focused: Bool) {
            guard let binding = field.isFocused else { return }
            requestedFocus = focused
            if binding.wrappedValue != focused { binding.wrappedValue = focused }
        }
    }
}

private final class StationaryPlaceholderField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard (currentEditor()?.string ?? stringValue).isEmpty,
              let placeholder = placeholderAttributedString?.string,
              let font, let cell else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: style,
        ]
        let content = cell.titleRect(forBounds: bounds)
        let height = (placeholder as NSString).size(withAttributes: attributes).height
        let rect = NSRect(x: content.minX, y: content.midY - height / 2,
                          width: content.width, height: height)
        (placeholder as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                       attributes: attributes)
    }
}

struct AccentIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.moss : Color.disabledInk)
            .modifier(ControlFocusFill())
            .brightness(enabled && configuration.isPressed ? -0.05 : 0)
            .focusEffectDisabled()
            .pointingHandCursor()
    }
}

private struct PlainControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlFocusFill())
            .brightness(configuration.isPressed ? -0.05 : 0)
            .focusEffectDisabled()
            .pointingHandCursor()
    }
}

private struct ControlFocusFill: ViewModifier {
    @Environment(\.controlFocused) private var focused
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View {
        content.overlay {
            if focused && enabled {
                RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius)
                    .fill(Color.moss.opacity(0.12))
                    .allowsHitTesting(false)
            }
        }
    }
}
