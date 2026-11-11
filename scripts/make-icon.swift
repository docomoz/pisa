import AppKit
import Foundation

// Original vector artwork. No background bitmap: pixels outside the tile stay transparent.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
let geometryURL = URL(fileURLWithPath: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Resources/BrandMark.json")
let geometry = try JSONSerialization.jsonObject(with: Data(contentsOf: geometryURL)) as! [String: [[Double]]]
let bars = geometry["bars"]!
let isVolumeIcon = CommandLine.arguments.dropFirst(3).first == "--volume"
// The favicon viewBox, expressed in the artwork's bottom-left coordinates.
let faviconBounds = NSRect(x: 192, y: 190, width: 640, height: 640)
for size in [16, 32, 128, 256, 512] {
    let isTitleIcon = isVolumeIcon && size == 16
    let inset: CGFloat = isTitleIcon ? 0 : 94
    let tileSize = 1024 - 2 * inset
    let cornerRadius: CGFloat = isTitleIcon ? 232 : 190
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(white: 0.98, alpha: 1).setFill()
        let tile = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: tileSize, height: tileSize), xRadius: cornerRadius, yRadius: cornerRadius)
        tile.fill()
        NSColor(white: 0.85, alpha: 1).setStroke(); tile.lineWidth = 2; tile.stroke()
        if isTitleIcon {
            context.scaleBy(x: 1024 / faviconBounds.width, y: 1024 / faviconBounds.height)
            context.translateBy(x: -faviconBounds.minX, y: -faviconBounds.minY)
        }
        NSColor(srgbRed: 0.22, green: 0.22, blue: 0.22, alpha: 1).setFill()
        for bar in bars {
            NSBezierPath(roundedRect: NSRect(x: bar[0], y: bar[1], width: bar[2], height: bar[3]), xRadius: bar[2]/2, yRadius: bar[2]/2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
    }
}
