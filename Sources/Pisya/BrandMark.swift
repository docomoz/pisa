import AppKit

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
