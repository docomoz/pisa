import AppKit
import SwiftUI

/// The same normalized geometry generates the app icon and menu bar template.
enum BrandMark {
    static let bars: [[Double]] = {
        guard let url = Bundle.main.url(forResource: "BrandMark", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: [[Double]]],
              let bars = value["bars"], bars.count == 5, bars.allSatisfy({ $0.count == 4 }) else { return [] }
        return bars
    }()
    static let ink = NSColor(srgbRed: 0.22, green: 0.22, blue: 0.22, alpha: 1)
    static let menuIcon = image(color: .black, template: true)
    static let headerIcon = image(color: ink, template: false)
    private static func image(color: NSColor, template: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            color.setFill()
            let scale = 18.0 / 600.0
            for bar in bars {
                let rect = NSRect(x: 1.3 + (bar[0] - 222) * scale, y: 1 + (bar[1] - 210) * scale, width: bar[2] * scale, height: bar[3] * scale)
                NSBezierPath(roundedRect: rect, xRadius: rect.width / 2, yRadius: rect.width / 2).fill()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}

struct AnimatedBrandMark: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat
    private static let animationKey = "logo-wave"

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let scale = size / 1024
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

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
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
