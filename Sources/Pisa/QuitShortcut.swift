import AppKit

enum QuitShortcut {
    static func terminate(_ application: NSApplication) {
        var windows = application.windows
        if let modal = application.modalWindow, !windows.contains(modal) { windows.append(modal) }
        var index = 0
        while index < windows.count {
            if let sheet = windows[index].attachedSheet, !windows.contains(sheet) { windows.append(sheet) }
            index += 1
        }
        let previous = windows.map { $0.preventsApplicationTerminationWhenModal }
        for window in windows { window.preventsApplicationTerminationWhenModal = false }
        application.terminate(nil)
        for (window, oldValue) in zip(windows, previous) { window.preventsApplicationTerminationWhenModal = oldValue }
    }

    static func install(quit: @escaping () -> Void) -> Any {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            guard modifiers == .command,
                  key == "q" || (key == "й" && event.keyCode == 12) else { return event }
            quit()
            return nil
        }!
    }
}
