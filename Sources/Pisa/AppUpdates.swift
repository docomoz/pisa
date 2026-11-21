import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdates: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdates()

    @Published private(set) var isReady = false
    @Published private(set) var startError: String?
    @Published private(set) var canCheck = false
    @Published private(set) var installsAutomatically = false
    @Published private(set) var hasInstallableUpdate = false
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []

    init(isReady: Bool = false, canCheck: Bool = false) {
        self.isReady = isReady
        self.canCheck = canCheck
    }

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            startError = error.localizedDescription
            NSLog("Pisa could not start the updater: %@", error.localizedDescription)
            return
        }

        self.controller = controller
        startError = nil
        isReady = true
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheck = $0 }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .sink { [weak self] in self?.installsAutomatically = $0 }
            .store(in: &observations)
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
