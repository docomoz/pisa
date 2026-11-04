import SwiftUI

enum PisyaDesign {
    enum Typography {
        static let button = Font.appFont(size: 16, weight: .medium)
        static let smallButton = Font.appFont(size: 13, weight: .medium)
    }
    enum Colors {
        // Bronegis light-theme OKLCH tokens converted to sRGB.
        static let ink = Color(red: 0.08727, green: 0.09624, blue: 0.10585)
        static let actionInk = Color(red: 0.13376, green: 0.45195, blue: 0.13214)
        static let brandAccent = Color(red: 0.26624, green: 0.72562, blue: 0.26006)
        static let brandAccentInk = Color(red: 0.02877, green: 0.07336, blue: 0.02674)
        static let primaryHover = Color(red: 0.21844, green: 0.65153, blue: 0.21485)
        static let primaryPressed = Color(red: 0.18, green: 0.59, blue: 0.18)
        static let secondary = Color(red: 0.95243, green: 0.95896, blue: 0.96604)
        static let secondaryHover = Color(red: 0.90895, green: 0.91760, blue: 0.92694)
        static let secondaryPressed = Color(red: 0.86, green: 0.88, blue: 0.89)
        static let recording = Color(red: 0.74508, green: 0.13808, blue: 0.13777)
        static let recordingHover = Color(red: 0.68, green: 0.11, blue: 0.11)
        static let recordingPressed = Color(red: 0.60, green: 0.09, blue: 0.09)
        static let disabledInk = Color(white: 0.42)
        static let disabledSurface = Color(white: 0.94)
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
        static let regularPadding: CGFloat = 16
        static let smallPadding: CGFloat = 12
    }
    enum Spacing {
        static let textLine: CGFloat = 7
        static let inline: CGFloat = 8
        static let related: CGFloat = 12
        static let content: CGFloat = 16
        static let section: CGFloat = 24
        static let sheetInset: CGFloat = 28
        static let page: CGFloat = 32
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String?
    var size: CGFloat = 19
    init(_ title: String, subtitle: String? = nil, size: CGFloat = 19) {
        self.title = title; self.subtitle = subtitle; self.size = size
    }
    var body: some View {
        VStack(alignment: .leading, spacing: PisyaDesign.Spacing.inline) {
            screenText(title).font(.appFont(size: size, weight: .semibold))
            if let subtitle {
                screenText(subtitle).foregroundStyle(Color.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.fixedSize(horizontal: false, vertical: true)
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
    func plainSurface(radius: CGFloat = 12) -> some View {
        background(PisyaDesign.Colors.secondary, in: RoundedRectangle(cornerRadius: radius))
    }
    func plainSelection(_ selected: Bool, radius: CGFloat = 10) -> some View {
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
    func shapeAwarePlainButton<Outline: Shape>(_ shape: Outline = RoundedRectangle(cornerRadius: 8)) -> some View {
        buttonStyle(PlainControlStyle()).controlKeyboardFocus()
    }
    func controlKeyboardFocus() -> some View { modifier(ControlKeyboardFocus()) }
}

private struct ControlFocusedKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var controlFocused: Bool {
        get { self[ControlFocusedKey.self] }
        set { self[ControlFocusedKey.self] = newValue }
    }
}
private struct ControlKeyboardFocus: ViewModifier {
    // Bind the control itself: macOS doesn't propagate its focus into a ButtonStyle label.
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.focused($focused)
            .environment(\.controlFocused, focused)
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
            return (pressed || focused) ? PisyaDesign.Colors.secondaryPressed : hovered ? PisyaDesign.Colors.secondaryHover : PisyaDesign.Colors.secondary
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
            .font(size == .small ? PisyaDesign.Typography.smallButton : PisyaDesign.Typography.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .small ? PisyaDesign.Metrics.smallPadding : PisyaDesign.Metrics.regularPadding)
            .frame(minHeight: size == .small ? PisyaDesign.Metrics.smallHeight : PisyaDesign.Metrics.regularHeight)
            .background(background, in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
            .focusEffectDisabled()
            .onHover { hovered = $0 }
    }
}

struct PisyaTextFieldStyle: TextFieldStyle {
    @Environment(\.isEnabled) private var enabled
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .foregroundStyle(enabled ? PisyaDesign.Colors.ink : PisyaDesign.Colors.disabledInk)
            .padding(.horizontal, 12)
            .frame(minHeight: PisyaDesign.Metrics.regularHeight)
            .background(enabled ? PisyaDesign.Colors.secondary : PisyaDesign.Colors.disabledSurface,
                        in: RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
            .contentShape(.focusEffect, RoundedRectangle(cornerRadius: PisyaDesign.Metrics.cornerRadius))
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
    }
}

private struct PlainControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ControlFocusFill())
            .brightness(configuration.isPressed ? -0.05 : 0)
            .focusEffectDisabled()
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
