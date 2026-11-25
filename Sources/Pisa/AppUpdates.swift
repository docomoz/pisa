import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()

    @Published private(set) var isReady = false
    @Published private(set) var canCheck = false
    @Published private(set) var installsAutomatically = false
    @Published private var hasDownloadedUpdate = false
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []

    var canInstallUpdate: Bool { hasDownloadedUpdate && canCheck }

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: self
        )
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            NSLog("Pisa could not start the updater: %@", error.localizedDescription)
            return
        }

        self.controller = controller
        isReady = true
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] in self?.installsAutomatically = $0 }
            .store(in: &observations)

        // Check before Sparkle schedules its first check using the last session's timestamp.
        checkAutomatically()
    }

    func checkAutomatically() {
        guard let updater = controller?.updater, updater.automaticallyChecksForUpdates,
              !updater.sessionInProgress else { return }
        // Keep Sparkle's automatic downloads available during checks triggered by app activity.
        updater.checkForUpdatesInBackground()
    }

    func check() {
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        hasDownloadedUpdate = true
        // Let Sparkle finish the background session so the update can be opened with check().
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        hasDownloadedUpdate = false
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip || choice == .install { hasDownloadedUpdate = false }
    }
}

// Sparkle calls its user-driver delegate on the main thread.
extension AppUpdates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus _: Bool) -> Bool {
        !installsAutomatically || update.isCriticalUpdate || update.isInformationOnlyUpdate || update.isMajorUpgrade
    }

    func standardUserDriverWillHandleShowingUpdate(_: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        hasDownloadedUpdate = !update.isInformationOnlyUpdate && (state.stage == .downloaded || state.stage == .installing)
    }
}
