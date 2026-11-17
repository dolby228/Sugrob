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
    /// On, or registered and waiting for approval in System Settings › Login Items
    /// (common with ad-hoc signing). A pending item counts as on so it can be turned off.
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Registered, but the user still has to allow it in System Settings.
    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Hint for the checkbox / menu item, `nil` when nothing is pending.
    static var hint: String? {
        requiresApproval
            ? "Ждёт разрешения: Системные настройки › Основные › Объекты входа"
            : nil
    }

    static func toggle() {
        let service = SMAppService.mainApp
        do {
            if isEnabled {
                try service.unregister()
                log.debug("unregistered login item")
            } else {
                try service.register()
                log.debug("registered login item, status \(String(describing: service.status), privacy: .public)")
            }
        } catch {
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
        if service.status == .requiresApproval {
            log.info("login item requires approval, opening Login Items settings")
            SMAppService.openSystemSettingsLoginItems()
        }
        NotificationCenter.default.post(name: .sugrobLaunchAtLoginDidChange, object: nil)
    }
}
