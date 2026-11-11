import AppKit
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
        window.title = typographicText("О программе Pisya")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self

        let hosting = NSHostingView(rootView: AboutView().onExitCommand { [weak window] in window?.close() })
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

private struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""

    var body: some View {
        VStack(spacing: PisyaDesign.Spacing.inline) {
            AboutLogo()
                .frame(width: AboutLogo.size, height: AboutLogo.size)
                .accessibilityHidden(true)
            VStack(spacing: PisyaDesign.Spacing.inline) {
                screenText("Pisya").textStyle(PisyaDesign.Typography.detailStrong)
                    .accessibilityAddTraits(.isHeader)
                screenText("Версия \(version) (\(build))").textStyle(PisyaDesign.Typography.micro)
            }
            VStack(spacing: PisyaDesign.Spacing.inline) {
                screenText("Максим Берёзкин")
                Link(destination: URL(string: "https://t.me/docomoz")!) {
                    screenText(verbatim: "t.me/docomoz").underline().foregroundStyle(Color(nsColor: .linkColor))
                }
                .shapeAwarePlainButton()
                screenText("Сделано нами для нас\u{00a0}💚")
            }
            .textStyle(PisyaDesign.Typography.detail)
        }
        .multilineTextAlignment(.center)
        .frame(minWidth: 228)
        .padding(.horizontal, PisyaDesign.Spacing.sheetInset)
        .padding(.top, PisyaDesign.Spacing.inline)
        .padding(.bottom, PisyaDesign.Spacing.content)
        .fixedSize()
    }
}

private struct AboutLogo: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    static let size: CGFloat = 68
    private static let animationKey = "logo-wave"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let scale = Self.size / 1024
        let tile = CALayer()
        tile.frame = CGRect(x: 94 * scale, y: 94 * scale, width: 836 * scale, height: 836 * scale)
        tile.cornerRadius = 190 * scale
        tile.backgroundColor = NSColor(white: 0.98, alpha: 1).cgColor
        tile.borderColor = NSColor(white: 0.85, alpha: 1).cgColor
        tile.borderWidth = 2 * scale
        view.layer?.addSublayer(tile)

        for bar in BrandMark.bars {
            let layer = CALayer()
            layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            layer.frame = CGRect(x: (bar[0] - 94) * scale, y: (bar[1] - 94) * scale,
                                 width: bar[2] * scale, height: bar[3] * scale)
            layer.cornerRadius = layer.bounds.width / 2
            layer.backgroundColor = BrandMark.ink.cgColor
            tile.addSublayer(layer)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let bars = view.layer?.sublayers?.first?.sublayers ?? []
        let start = CACurrentMediaTime()
        for (index, bar) in bars.enumerated() {
            if reduceMotion {
                bar.removeAnimation(forKey: Self.animationKey)
            } else if bar.animation(forKey: Self.animationKey) == nil {
                // Match the hero's bottom-anchored logo-wave and logo-finger in website/dist/style.css.
                let distanceFromCenter = abs(index - 2)
                let animation = CAKeyframeAnimation(keyPath: "transform.scale.y")
                if distanceFromCenter == 0 {
                    animation.keyTimes = [0, 0.10, 0.22, 0.42, 0.49, 0.68, 1]
                    animation.values = [1, 1, 0.96, 1.15, 1.15, 1, 1]
                } else {
                    animation.keyTimes = [0, 0.12, 0.22, 0.37, 0.54, 1]
                    animation.values = [1, 1, 0.88, 1.16, 1, 1]
                }
                animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                                                  count: (animation.keyTimes?.count ?? 1) - 1)
                animation.duration = 9
                animation.repeatCount = .infinity
                animation.beginTime = bar.convertTime(start, from: nil) + 0.16 * Double(distanceFromCenter)
                bar.add(animation, forKey: Self.animationKey)
            }
        }
    }
}
