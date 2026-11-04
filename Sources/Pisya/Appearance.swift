import SwiftUI

extension View {
    func popupCanvas() -> some View {
        foregroundStyle(Color.ink).tint(Color.moss).background(Color.paper)
            .background(SlimScrollbars().allowsHitTesting(false))
    }
    func plainSurface(radius: CGFloat = 12) -> some View {
        background(Color.white, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(Color.black.opacity(0.10), lineWidth: 1) }
    }
    func plainSelection(_ selected: Bool, radius: CGFloat = 10) -> some View {
        background {
            if selected {
                RoundedRectangle(cornerRadius: radius).fill(Color.selectionTint)
                    .allowsHitTesting(false)
            }
        }
    }
    func plainControls() -> some View { buttonStyle(PlainActionStyle()).contentShape(.focusEffect, Capsule()) }
    func plainButton(prominent: Bool = false, color: Color = .moss, neutral: Bool = false) -> some View {
        buttonStyle(PlainActionStyle(prominent: prominent, color: color, neutral: neutral)).contentShape(.focusEffect, Capsule())
    }
}
private struct PlainActionStyle: ButtonStyle {
    var prominent = false
    var color: Color = .moss
    var neutral = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 18)
            .foregroundStyle(enabled ? (prominent ? Color.white : (neutral ? Color.ink : color)) : Color.disabledInk)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(enabled ? (prominent ? color : (neutral ? Color.white : Color.actionTint)) : Color.disabledTint, in: Capsule())
            .overlay { Capsule().strokeBorder(enabled ? (neutral ? Color.black.opacity(0.14) : color.opacity(prominent ? 1 : 0.24)) : Color.disabledInk.opacity(0.22), lineWidth: 1) }
            .contentShape(.focusEffect, Capsule())
            .brightness(enabled && configuration.isPressed ? -0.045 : 0)
    }
}

extension View {
    func shapeAwarePlainButton<Outline: Shape>(_ shape: Outline = RoundedRectangle(cornerRadius: 8)) -> some View {
        buttonStyle(.plain).contentShape(.focusEffect, shape)
    }
}

struct AccentIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.moss : Color.disabledInk)
            .brightness(enabled && configuration.isPressed ? -0.05 : 0)
            .contentShape(.focusEffect, Circle())
    }
}
