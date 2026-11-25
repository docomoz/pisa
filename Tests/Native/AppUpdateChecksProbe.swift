import AppKit
import Combine
import CryptoKit
import Sparkle

@main
enum AppUpdateChecksProbe {
    @MainActor
    static func main() throws {
        let scenario = CommandLine.arguments[1]
        if scenario == "fixture-key" {
            let key = Curve25519.Signing.PrivateKey()
            try key.rawRepresentation.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print(key.publicKey.rawRepresentation.base64EncodedString())
            return
        }
        if scenario == "sign-fixture" {
            let keyData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
            let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
            print(try key.signature(for: archive).base64EncodedString())
            return
        }

        let app = NSApplication.shared
        UserDefaults.standard.register(defaults: ["SULastCheckTime": Date()])
        var foundUpdate = false
        let discovery = NotificationCenter.default.publisher(for: .SUUpdaterDidFindValidUpdate)
            .sink { _ in foundUpdate = true }
        defer { discovery.cancel() }
        let updates = AppUpdates.shared
        updates.start()
        require(updates.isReady, "Sparkle failed to start")

        switch scenario {
        case "activity":
            require(wait { updates.canCheck }, "The launch check did not finish")
            require(!updates.canInstallUpdate, "An up-to-date launch response should leave the update link hidden")
            updates.checkAutomatically()
            updates.checkAutomatically()
        case "disabled":
            updates.checkAutomatically()
            require(updates.canCheck, "Automatic checks should respect Sparkle's opt-out")
            updates.check()
            require(wait { foundUpdate && updates.canCheck && app.windows.contains(where: \.isVisible) },
                    "The manual check should still find and show the update")
            require(!updates.canInstallUpdate, "A manually discovered update has not been downloaded")
            return
        case "download":
            let markers = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let downloadStarted = markers.appendingPathComponent("download-started")
            require(wait { FileManager.default.fileExists(atPath: downloadStarted.path) }, "The background download did not start")
            require(!updates.canInstallUpdate, "The install link appeared during the download")
            try Data().write(to: markers.appendingPathComponent("finish-download"))
            require(wait { updates.canInstallUpdate }, "The completed update did not enable the install link")
            require(!app.windows.contains(where: \.isVisible), "The background download opened an update window")
            foundUpdate = false
            updates.check()
            require(wait { foundUpdate && updates.canCheck && app.windows.contains(where: \.isVisible) },
                    "The install link did not open Sparkle for the downloaded update")
            return
        case "failed-download":
            require(wait { foundUpdate && updates.canCheck }, "The failed download did not finish")
            require(!updates.canInstallUpdate, "A failed download should leave the install link hidden")
            return
        default:
            break
        }

        require(wait { foundUpdate && updates.canCheck }, "The background check did not find the update")
        require(!updates.canInstallUpdate, "Finding an update before downloading it should leave the install link hidden")
        // Sparkle may defer a scheduled alert until the user returns to the app.
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: app)
        require(wait { app.windows.contains(where: \.isVisible) },
                "Sparkle should show its update prompt when automatic downloads are disabled")
    }

    @MainActor
    private static func wait(for condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(12)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
}
