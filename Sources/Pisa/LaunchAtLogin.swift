import Combine
import ServiceManagement

@MainActor
protocol LoginItemRegistration {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemRegistration {}

@MainActor
final class LaunchAtLogin: ObservableObject {
    // The native menu uses this title directly, so keep the preposition bound here.
    static let title = "Запускать при\u{00A0}входе"

    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: String?

    private let service: any LoginItemRegistration
    private let openSettings: () -> Void

    init(service: (any LoginItemRegistration)? = nil,
         openSettings: @escaping () -> Void = SMAppService.openSystemSettingsLoginItems) {
        let service = service ?? SMAppService.mainApp
        self.service = service
        self.openSettings = openSettings
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }

    func refresh() {
        let currentStatus = service.status
        if currentStatus != status {
            status = currentStatus
            error = nil
        }
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        error = nil
        do {
            switch (enabled, status) {
            case (true, .notRegistered), (true, .notFound): try service.register()
            case (false, .enabled), (false, .requiresApproval): try service.unregister()
            default: break
            }
        } catch {
            let action = enabled ? "включить" : "выключить"
            self.error = "Не удалось \(action) запуск при входе. \(error.localizedDescription)"
        }
        refresh()
        if enabled && status == .requiresApproval { openSettings() }
    }
}
