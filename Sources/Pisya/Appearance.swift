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
    func plainControls() -> some View { buttonStyle(PlainActionStyle()) }
    func plainButton(prominent: Bool = false, color: Color = .moss) -> some View {
        buttonStyle(PlainActionStyle(prominent: prominent, color: color))
    }
}
private struct PlainActionStyle: ButtonStyle {
    var prominent = false
    var color: Color = .moss
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minHeight: 18)
            .foregroundStyle(prominent ? Color.white : Color.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(prominent ? color : Color.white, in: Capsule())
            .overlay { Capsule().strokeBorder(prominent ? color : Color.black.opacity(0.14), lineWidth: 1) }
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.38)
    }
}
