import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

/// Shows Sugrob in the Dock (regular app with a main menu) or hides it (menu-bar-only accessory).
///
/// The bundle is `LSUIElement`, so it starts as an accessory; `apply` switches the policy at runtime.
/// The Dock icon matters on notched Macs, where the status item is often hidden: clicking it
/// reopens the app (settings window) and its context menu has the main controls.
@MainActor
final class DockPresence: NSObject {
    private let settings: Settings
    var onOpenSettings: (() -> Void)?

    init(settings: Settings) {
        self.settings = settings
        super.init()
    }

    func apply() {
        let policy: NSApplication.ActivationPolicy = settings.showInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        if policy == .regular {
            NSApp.mainMenu = makeMainMenu()
        }
        if !NSApp.setActivationPolicy(policy) {
            log.error("could not switch activation policy to \(policy.rawValue, privacy: .public)")
        } else {
            log.info("dock icon \(self.settings.showInDock ? "shown" : "hidden", privacy: .public)")
        }
    }

    /// Context menu of the Dock icon. AppKit appends its own items (Options, Quit).
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item(settings.isPaused ? "Продолжить" : "Пауза", #selector(togglePause(_:))))
        menu.addItem(item("Очистить сугробы", #selector(clearAll(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Настройки…", #selector(openSettings(_:))))
        return menu
    }

    /// Minimal main menu shown while Sugrob is a regular app and frontmost.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Sugrob")
        appMenu.addItem(
            withTitle: "О Sugrob",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(item("Настройки…", #selector(openSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Скрыть Sugrob", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Выйти из Sugrob", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause(_ sender: NSMenuItem) {
        settings.isPaused.toggle()
    }

    @objc private func clearAll(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .sugrobClearAll, object: nil)
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?()
    }
}
