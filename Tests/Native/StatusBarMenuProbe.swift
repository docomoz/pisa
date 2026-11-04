import AppKit
import Combine

// Keep the real status-menu controller; replace audio and library services for this layout probe.
@MainActor
final class AppState: ObservableObject {
    struct Preferences { var automaticRecording = false }
    @Published var recording = false
    @Published var recordingStarted: Date?
    @Published var starting = false
    @Published var demo = false
    @Published var preferences = Preferences()
    var processingID: UUID?
    var message: String?
    func setAutomatic(_ enabled: Bool) { preferences.automaticRecording = enabled }
    func startRecording() async { recording = true }
    func stopRecording(manual: Bool) async { recording = false }
}

enum BrandMark { static var menuIcon: NSImage { NSImage(size: NSSize(width: 16, height: 16)) } }
enum PisyaDesign {
    enum Metrics { static let cornerRadius: CGFloat = 8 }
    enum Spacing {
        static let menuItemInset: CGFloat = 5
        static let inline: CGFloat = 8
        static let related: CGFloat = 12
        static let content: CGFloat = 16
        static let section: CGFloat = 24
    }
}
func recordingTimecode(_ elapsed: TimeInterval) -> String { "00:01" }

@main
enum StatusBarMenuProbe {
    @MainActor
    static func main() {
        _ = NSApplication.shared
        let state = AppState()
        let controller = StatusBarController(state: state, openMain: {})
        let menu = Mirror(reflecting: controller).children.compactMap { $0.value as? NSMenu }.first!
        let automatic = menu.items.first { $0.title == "Автоматическая запись" }!

        func measure(_ enabled: Bool) -> NSSize {
            state.setAutomatic(enabled)
            controller.menuWillOpen(menu)
            menu.update()
            let size = menu.size
            controller.menuDidClose(menu)
            return size
        }
        let off = measure(false)
        let on = measure(true)
        let offAgain = measure(false)
        print("MENU_SIZES off=\(off) on=\(on) offAgain=\(offAgain)")
        guard off == on, on == offAgain else {
            fputs("FAIL: toggling automatic recording changes the menu geometry\n", stderr)
            exit(1)
        }
        guard let control = automatic.view as? NSButton, let action = control.action else {
            fputs("FAIL: automatic recording must remain interactive inside the menu\n", stderr)
            exit(1)
        }
        let window = NSWindow(contentRect: control.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        let material = NSVisualEffectView(frame: control.bounds)
        material.material = .menu
        material.state = .active
        material.appearance = NSAppearance(named: .vibrantLight)
        window.contentView = material
        material.addSubview(control)

        // A prior click may leave keyboard focus on the checkbox while the mouse
        // moves through other items and separators. Only the menu's current item
        // may paint the selection background.
        window.makeFirstResponder(control)
        let normalItem = menu.items.first { !$0.isSeparatorItem && $0 !== automatic }!
        let transitions: [(NSMenuItem?, Bool)] = [
            (automatic, true), (normalItem, false), (nil, false),
            (automatic, true), (nil, false), (normalItem, false), (automatic, true)
        ]
        let originalFrame = control.frame
        for (item, expectedSelection) in transitions {
            controller.menu(menu, willHighlight: item)
            control.layoutSubtreeIfNeeded()
            let bitmap = control.bitmapImageRepForCachingDisplay(in: control.bounds)!
            control.cacheDisplay(in: control.bounds, to: bitmap)
            let scale = CGFloat(bitmap.pixelsWide) / control.bounds.width
            let pixel = bitmap.colorAt(x: Int(PisyaDesign.Spacing.inline * scale), y: bitmap.pixelsHigh / 2)!
            let paintedSelection = pixel.alphaComponent > 0.9
            guard paintedSelection == expectedSelection, control.frame == originalFrame, menu.size == off else {
                fputs("FAIL: mouse selection jumps back to the focused checkbox or changes row geometry\n", stderr)
                exit(1)
            }
        }
        controller.menuDidClose(menu)
        var indicatorsVisible = true
        for expected in [true, false] {
            NSApp.sendAction(action, to: control.target, from: control)
            guard state.preferences.automaticRecording == expected,
                  control.state == (expected ? .on : .off), menu.size == off else {
                fputs("FAIL: checkbox activation must update the setting and checkmark without changing menu geometry\n", stderr)
                exit(1)
            }
            for selected in [false, true] {
                window.makeFirstResponder(selected ? control : nil)
                controller.menu(menu, willHighlight: selected ? automatic : nil)
                control.needsDisplay = true
                control.layoutSubtreeIfNeeded()
                let bitmap = control.bitmapImageRepForCachingDisplay(in: control.bounds)!
                control.cacheDisplay(in: control.bounds, to: bitmap)
                do {
                    let checkbox = control.subviews.first { !($0 is NSTextField) }!
                    let rect = checkbox.convert(checkbox.bounds.insetBy(dx: 2, dy: 2), to: control)
                    let scale = CGFloat(bitmap.pixelsWide) / control.bounds.width
                    var visiblePixels = 0
                    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
                        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
                            if let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - y - 1)?.usingColorSpace(.sRGB) {
                                let channel = min(color.redComponent, color.greenComponent, color.blueComponent)
                                let visible = selected
                                    ? color.alphaComponent > 0.9 && channel > 0.85
                                    : channel * color.alphaComponent + 1 - color.alphaComponent < 0.75
                                if visible { visiblePixels += 1 }
                            }
                        }
                    }
                    print("INDICATOR_VISIBLE_PIXELS on=\(expected) selected=\(selected) count=\(visiblePixels)")
                    indicatorsVisible = indicatorsVisible && visiblePixels >= 10
                }
                if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.indices.contains(index + 1) {
                    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let image = NSImage(size: control.bounds.size)
                    image.lockFocus()
                    NSColor.white.setFill()
                    control.bounds.fill()
                    let cached = NSImage(size: control.bounds.size)
                    cached.addRepresentation(bitmap)
                    cached.draw(in: control.bounds, from: .zero, operation: .sourceOver, fraction: 1)
                    image.unlockFocus()
                    let opaque = NSBitmapImageRep(data: image.tiffRepresentation!)!
                    let name = "automatic-\(expected ? "on" : "off")-\(selected ? "selected" : "normal").png"
                    try! opaque.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
                }
            }
        }
        window.makeFirstResponder(nil)
        guard indicatorsVisible else {
            fputs("FAIL: checkbox indicator must remain visible in every checked and selected state\n", stderr)
            exit(1)
        }
        state.recording = true
        state.recordingStarted = Date()
        controller.menuWillOpen(menu)
        menu.update()
        guard menu.size == off, menu.items.contains(where: { $0.title == "Остановить запись" }) else {
            fputs("FAIL: starting a recording must preserve menu geometry and expose the stop action\n", stderr)
            exit(1)
        }
        controller.menuDidClose(menu)
        print("STATUS_MENU_LAYOUT_OK pointer_transitions repeated_toggle fixed_geometry synchronized_checkmark recording_layout")
    }
}
