// Renders the DMG window background at 1x and 2x:
//   swift make-dmg-background.swift <out-prefix> <width> <height> <appX> <appsX> <iconY>
// → <out-prefix>.tiff with 1x and 2x images. Sizes and positions are in points, y from the top,
// matching the Finder window layout set up in build.sh.
//
// A short Russian instruction explains the drag-to-Applications step.
//
// Finder draws icon labels black in light mode and white in dark mode, so the band behind the labels
// is kept mid-tone: readable in both.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let prefix = args[1]
let width = CGFloat(Double(args[2])!), height = CGFloat(Double(args[3])!)
let appX = CGFloat(Double(args[4])!), appsX = CGFloat(Double(args[5])!), iconY = CGFloat(Double(args[6])!)
let space = CGColorSpaceCreateDeviceRGB()
let bleed: CGFloat = 40  // extra canvas below the window, shown only if the title bar is shorter than expected

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int((height + bleed) * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height + bleed)
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Drawing below uses points with y going down from the top, like Finder.
    ctx.translateBy(x: 0, y: height + bleed)
    ctx.scaleBy(x: 1, y: -1)

    // Deep moss fading into sage where the icon labels sit.
    let base = CGGradient(colorsSpace: space, colors: [rgb(0x1C3029), rgb(0x3D5C48), rgb(0x748376)] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: height), options: [.drawsAfterEndLocation])

    func glow(_ center: CGPoint, _ radius: CGFloat, _ color: UInt32, _ alpha: CGFloat) {
        let g = CGGradient(colorsSpace: space, colors: [rgb(color, alpha), rgb(color, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    glow(CGPoint(x: width * 0.12, y: height * 0.15), width * 0.45, 0x9ED8A3, 0.55)
    glow(CGPoint(x: width * 0.92, y: height * 0.95), width * 0.5, 0xB7DFA2, 0.38)
    glow(CGPoint(x: width * 0.85, y: height * 0.05), width * 0.3, 0xE7D7A7, 0.22)

    // Faint stars in the dark upper part.
    var seed: UInt64 = 7
    func random() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(seed >> 33) / CGFloat(1 << 31)
    }
    for _ in 0..<46 {
        let p = CGPoint(x: random() * width, y: random() * height * 0.55)
        let r = 0.4 + random() * 0.9
        ctx.setFillColor(rgb(0xFFFFFF, 0.15 + random() * 0.4 * (1 - p.y / (height * 0.55))))
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    }

    // Keep the short preposition attached to the folder name; the instruction fits one line.
    let instruction = NSAttributedString(string: "Перенесите Pisya в\u{00A0}Приложения", attributes: [
        .font: NSFont.systemFont(ofSize: 25, weight: .semibold),
        .foregroundColor: NSColor.white
    ])
    let line = CTLineCreateWithAttributedString(instruction)
    let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    precondition(textWidth <= width - 80, "Installer instruction does not fit")
    ctx.saveGState()
    ctx.translateBy(x: (width - textWidth) / 2, y: 84)
    ctx.scaleBy(x: 1, y: -1)
    ctx.textMatrix = .identity
    ctx.textPosition = .zero
    ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 10, color: rgb(0x10251A, 0.45))
    CTLineDraw(line, ctx)
    ctx.restoreGState()

    // Arrow from the app to Applications: a gentle arch with a rounded head.
    let iconHalf: CGFloat = 64, pad: CGFloat = 22
    let start = CGPoint(x: appX + iconHalf + pad, y: iconY + 4)
    let end = CGPoint(x: appsX - iconHalf - pad, y: iconY + 4)
    let control = CGPoint(x: (start.x + end.x) / 2, y: iconY - 26)
    let shaft = CGMutablePath()
    shaft.move(to: start)
    shaft.addQuadCurve(to: end, control: control)
    // Arrowhead aligned with the curve's end tangent.
    let angle = atan2(end.y - control.y, end.x - control.x)
    let headLength: CGFloat = 15, spread: CGFloat = .pi / 4.6
    let head = CGMutablePath()
    head.move(to: CGPoint(x: end.x - headLength * cos(angle - spread), y: end.y - headLength * sin(angle - spread)))
    head.addLine(to: end)
    head.addLine(to: CGPoint(x: end.x - headLength * cos(angle + spread), y: end.y - headLength * sin(angle + spread)))

    let arrow = CGMutablePath()
    arrow.addPath(shaft)
    arrow.addPath(head)
    let stroked = arrow.copy(strokingWithWidth: 5, lineCap: .round, lineJoin: .round, miterLimit: 10)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 16, color: rgb(0xD8F2CB, 0.7))
    ctx.addPath(stroked)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(stroked)
    ctx.clip()
    let fill = CGGradient(colorsSpace: space, colors: [rgb(0xE2EED8), rgb(0xFFFFFF), rgb(0xDDF1D8)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(fill, start: CGPoint(x: start.x, y: 0), end: CGPoint(x: end.x, y: 0), options: [])
    ctx.restoreGState()

    NSGraphicsContext.current = nil
    return rep
}

// Encode pixels with only display properties; omit author, software and source-file metadata.
let output = URL(fileURLWithPath: prefix + ".tiff")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
for scale in [CGFloat(1), CGFloat(2)] {
    let bitmap = render(scale: scale)
    let properties: [CFString: Any] = [
        kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5]
    ]
    CGImageDestinationAddImage(destination, bitmap.cgImage!, properties as CFDictionary)
}
precondition(CGImageDestinationFinalize(destination), "Could not save installer background")
let verification = CGImageSourceCreateWithURL(output as CFURL, nil)!
precondition(CGImageSourceGetCount(verification) == 2)
for index in 0..<2 {
    let properties = CGImageSourceCopyPropertiesAtIndex(verification, index, nil)! as NSDictionary
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? NSDictionary
    precondition(tiff?[kCGImagePropertyTIFFSoftware] == nil)
    precondition(tiff?[kCGImagePropertyTIFFArtist] == nil)
    precondition(tiff?[kCGImagePropertyTIFFImageDescription] == nil)
    precondition(properties[kCGImagePropertyIPTCDictionary] == nil)
    precondition(properties[kCGImagePropertyExifDictionary] == nil)
}
