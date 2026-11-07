import AppKit

@main
struct QuitShortcutProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        window.beginSheet(sheet)
        var quits = 0
        let monitor = QuitShortcut.install { quits += 1 }
        func send(_ text: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: sheet.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: keyCode)!
            app.sendEvent(event)
        }
        send("q", keyCode: 12, modifiers: .command)
        send("й", keyCode: 12, modifiers: .command)
        precondition(quits == 2, "Command-Q must be handled in a sheet for both keyboard layouts")
        send("q", keyCode: 12, modifiers: [.command, .shift])
        send("q", keyCode: 12, modifiers: [.command, .option])
        send("q", keyCode: 12, modifiers: [.command, .control])
        send("w", keyCode: 13, modifiers: .command)
        send("q", keyCode: 12, modifiers: [])
        precondition(quits == 2, "Other shortcuts must not quit")
        NSEvent.removeMonitor(monitor)
        window.endSheet(sheet)
        print("QUIT_SHORTCUT_TEST_OK")
    }
}
