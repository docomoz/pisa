import AppKit

@main
enum AppUpdateChecksProbe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        UserDefaults.standard.register(defaults: ["SULastCheckTime": Date()])
        let updates = AppUpdates.shared
        updates.start()
        require(updates.isReady, "Sparkle failed to start")

        switch CommandLine.arguments[1] {
        case "activity":
            require(wait { updates.canCheck }, "The launch check did not finish")
            require(!updates.hasInstallableUpdate, "An up-to-date launch response should leave the update link hidden")
            updates.checkAutomatically()
            updates.checkAutomatically()
        case "disabled":
            updates.checkAutomatically()
            require(updates.canCheck, "Automatic checks should respect Sparkle's opt-out")
            updates.check()
            require(wait { updates.hasInstallableUpdate && app.windows.contains(where: \.isVisible) },
                    "The manual check should still find and show the update")
            return
        default:
            break
        }

        require(wait { updates.hasInstallableUpdate && updates.canCheck },
                "The app did not surface the available update after a recent check")
        require(!app.windows.contains(where: \.isVisible), "The automatic check opened an update window")
        if CommandLine.arguments[1] == "download" { return }
        updates.check()
        require(wait { app.windows.contains(where: \.isVisible) }, "The update action did not open Sparkle")
    }

    @MainActor
    private static func wait(for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(7)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
