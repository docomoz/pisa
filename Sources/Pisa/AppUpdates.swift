import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()

    @Published private(set) var isReady = false
    @Published private(set) var canCheck = false
    @Published private(set) var installsAutomatically = false
    @Published private(set) var hasInstallableUpdate = false
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []

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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        hasInstallableUpdate = !item.isInformationOnlyUpdate
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        hasInstallableUpdate = false
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { hasInstallableUpdate = false }
    }
}

// Sparkle calls its user-driver delegate on the main thread.
extension AppUpdates: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus _: Bool) -> Bool {
        update.isCriticalUpdate || update.isInformationOnlyUpdate
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate _: SUAppcastItem, state _: SPUUserUpdateState) {
        if !handleShowingUpdate && !hasInstallableUpdate { hasInstallableUpdate = true }
    }
}
