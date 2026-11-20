import AppKit
import Combine
import ServiceManagement

protocol LoginItemRegistration: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistration {}

@MainActor
final class LaunchAtLogin: ObservableObject {
    // The native menu uses this title directly, so keep the preposition bound here.
    static let title = "Запускать при\u{00A0}входе"

    @Published private(set) var isEnabled = false
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var error: String?

    private struct Change {
        let enabled: Bool
        let onError: ((String) -> Void)?
    }

    private let service: any LoginItemRegistration
    private let openSettings: () -> Void
    private let queue = DispatchQueue(label: "Pisa.login-item", qos: .userInitiated)
    private var change: Change?
    private var changeWaiters: [CheckedContinuation<Void, Never>] = []
    private var isRefreshing = false

    init(service: any LoginItemRegistration = SMAppService.mainApp,
         openSettings: @escaping () -> Void = SMAppService.openSystemSettingsLoginItems) {
        self.service = service
        self.openSettings = openSettings
        refresh()
    }

    func refresh() {
        guard change == nil, !isRefreshing else { return }
        isRefreshing = true
        readStatus { [weak self] status, _ in
            guard let self else { return }
            isRefreshing = false
            guard change == nil, self.status != status else { return }
            applyStatus(status)
            error = nil
        }
    }

    func setEnabled(_ enabled: Bool, onError: ((String) -> Void)? = nil) {
        let shouldStart = change == nil
        change = Change(enabled: enabled, onError: onError)
        isEnabled = enabled
        if error != nil { error = nil }
        if shouldStart { updateRegistration(enabled) }
    }

    var hasPendingChange: Bool { change != nil }

    func waitForPendingChange() async {
        guard hasPendingChange else { return }
        await withCheckedContinuation { changeWaiters.append($0) }
    }

    private func updateRegistration(_ enabled: Bool) {
        readStatus(applying: enabled) { [weak self] status, error in
            guard let self, let change else { return }
            // A newer click already set the checkmark. Apply only its latest value.
            if change.enabled != enabled {
                updateRegistration(change.enabled)
                return
            }
            self.change = nil
            applyStatus(status)
            self.error = error
            for waiter in changeWaiters { waiter.resume() }
            changeWaiters.removeAll()
            if let error { change.onError?(error) }
            if enabled && status == .requiresApproval { openSettings() }
        }
    }

    private func applyStatus(_ status: SMAppService.Status) {
        if self.status != status { self.status = status }
        let enabled = status == .enabled
        if isEnabled != enabled { isEnabled = enabled }
    }

    private func readStatus(applying enabled: Bool? = nil,
                            completion: @escaping @MainActor @Sendable (SMAppService.Status, String?) -> Void) {
        queue.async { [service] in
            let initialStatus = service.status
            let result: (SMAppService.Status, String?)
            do {
                switch (enabled, initialStatus) {
                case (true?, .notRegistered), (true?, .notFound):
                    try service.register()
                    result = (service.status, nil)
                case (false?, .enabled), (false?, .requiresApproval):
                    try service.unregister()
                    result = (service.status, nil)
                default:
                    result = (initialStatus, nil)
                }
            } catch {
                let action = enabled == true ? "включить" : "выключить"
                result = (service.status, "Не удалось \(action) запуск при входе. \(error.localizedDescription)")
            }
            // Deliver the result even while AppKit is tracking an open status menu.
            RunLoop.main.perform(inModes: [.common, .eventTracking]) {
                MainActor.assumeIsolated { completion(result.0, result.1) }
            }
        }
    }
}
