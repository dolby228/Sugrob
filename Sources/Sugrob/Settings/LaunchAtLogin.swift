import Foundation
import ServiceManagement
import os

private let log = Logger(subsystem: "dev.sugrob", category: "settings")

extension Notification.Name {
    /// Posted after «Запускать при входе» was toggled, so every control can refresh.
    static let sugrobLaunchAtLoginDidChange = Notification.Name("dev.sugrob.launchAtLoginDidChange")
}

/// «Запускать при входе» via `SMAppService.mainApp`. The state lives in the system, not in `Settings`.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                log.debug("unregistered login item")
            } else {
                try service.register()
                log.debug("registered login item, status \(String(describing: service.status), privacy: .public)")
            }
        } catch {
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: .sugrobLaunchAtLoginDidChange, object: nil)
    }
}
