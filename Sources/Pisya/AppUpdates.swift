import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()

    @Published private(set) var isReady = false
    @Published private(set) var canCheck = false
    @Published private(set) var installsAutomatically = false
    private var controller: SPUStandardUpdaterController?
    private var observations: Set<AnyCancellable> = []

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        let updater = controller.updater
        do {
            try updater.start()
        } catch {
            NSLog("Pisya could not start the updater: %@", error.localizedDescription)
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
    }

    func check() {
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticInstallation(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }
}
