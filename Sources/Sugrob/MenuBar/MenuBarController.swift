import AppKit
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "menu")

/// Status bar item with all user controls. Labels are in Russian.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// «Настройки…».
    var onOpenSettings: (() -> Void)?

    private let settings: Settings
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let pauseItem = NSMenuItem()
    private var snowfallItems: [NSMenuItem] = []
    private var windItems: [NSMenuItem] = []
    private var toolItems: [NSMenuItem] = []
    private let debugItem = NSMenuItem()
    private let loginItem = NSMenuItem()

    init(settings: Settings) {
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Sugrob") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "❄"
            }
            button.toolTip = "Sugrob"
        }

        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStates()

        settings.addObserver { [weak self] _ in
            self?.refreshStates()
        }
    }

    // MARK: Building

    private func buildMenu() {
        menu.autoenablesItems = false

        pauseItem.action = #selector(togglePause(_:))
        pauseItem.target = self
        pauseItem.keyEquivalent = "p"
        pauseItem.keyEquivalentModifierMask = [.command]
        menu.addItem(pauseItem)
        menu.addItem(.separator())

        let snowfallMenu = NSMenu()
        for (index, entry) in Settings.snowfallTitles.enumerated() {
            let item = NSMenuItem(title: entry.1, action: #selector(selectSnowfall(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            snowfallMenu.addItem(item)
            snowfallItems.append(item)
        }
        menu.addItem(submenuItem(title: "Снегопад", submenu: snowfallMenu))

        let windMenu = NSMenu()
        for (index, preset) in Settings.windPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(selectWind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            windMenu.addItem(item)
            windItems.append(item)
        }
        menu.addItem(submenuItem(title: "Ветер", submenu: windMenu))

        let toolMenu = NSMenu()
        for (index, entry) in Settings.toolTitles.enumerated() {
            let item = NSMenuItem(title: entry.1, action: #selector(selectTool(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            toolMenu.addItem(item)
            toolItems.append(item)
        }
        toolMenu.addItem(.separator())
        let snowballHint = NSMenuItem(title: Settings.snowballHint, action: nil, keyEquivalent: "")
        snowballHint.isEnabled = false
        toolMenu.addItem(snowballHint)
        menu.addItem(submenuItem(title: "Инструмент", submenu: toolMenu))

        let clearItem = NSMenuItem(title: "Очистить сугробы", action: #selector(clearAll(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        menu.addItem(.separator())

        debugItem.title = "Показывать контуры окон"
        debugItem.action = #selector(toggleDebugOutlines(_:))
        debugItem.target = self
        menu.addItem(debugItem)

        loginItem.title = "Запускать при входе"
        loginItem.action = #selector(toggleLaunchAtLogin(_:))
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let diagnosticsItem = NSMenuItem(
            title: "Скопировать диагностику",
            action: #selector(copyDiagnostics(_:)),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let aboutItem = NSMenuItem(title: "О Sugrob", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let settingsItem = NSMenuItem(title: "Настройки…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        submenu.autoenablesItems = false
        item.submenu = submenu
        return item
    }

    // MARK: State

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStates()
    }

    private func refreshStates() {
        pauseItem.title = settings.isPaused ? "Продолжить" : "Пауза"

        let snowfall = settings.snowfall
        for (item, entry) in zip(snowfallItems, Settings.snowfallTitles) {
            item.state = entry.0 == snowfall ? .on : .off
        }

        let windX = settings.windX
        let windY = settings.windY
        for (item, preset) in zip(windItems, Settings.windPresets) {
            item.state = preset.matches(x: windX, y: windY) ? .on : .off
        }

        let tool = settings.tool
        for (item, entry) in zip(toolItems, Settings.toolTitles) {
            item.state = entry.0 == tool ? .on : .off
        }

        let forced = DebugOverlayView.environmentForcesOutlines
        debugItem.state = (settings.showDebugOutlines || forced) ? .on : .off
        debugItem.isEnabled = !forced
        debugItem.toolTip = forced ? "Включено через SUGROB_DEBUG_WINDOWS=1" : nil

        loginItem.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    // MARK: Actions

    @objc private func togglePause(_ sender: NSMenuItem) {
        settings.isPaused.toggle()
    }

    @objc private func selectSnowfall(_ sender: NSMenuItem) {
        guard Settings.snowfallTitles.indices.contains(sender.tag) else { return }
        settings.snowfall = Settings.snowfallTitles[sender.tag].0
    }

    @objc private func selectWind(_ sender: NSMenuItem) {
        guard Settings.windPresets.indices.contains(sender.tag) else { return }
        let preset = Settings.windPresets[sender.tag]
        settings.setWind(x: preset.x, y: preset.y)
    }

    @objc private func selectTool(_ sender: NSMenuItem) {
        guard Settings.toolTitles.indices.contains(sender.tag) else { return }
        settings.tool = Settings.toolTitles[sender.tag].0
    }

    @objc private func clearAll(_ sender: NSMenuItem) {
        NotificationCenter.default.post(name: .sugrobClearAll, object: nil)
    }

    @objc private func toggleDebugOutlines(_ sender: NSMenuItem) {
        settings.showDebugOutlines.toggle()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        LaunchAtLogin.toggle()
        refreshStates()
    }

    @objc private func copyDiagnostics(_ sender: NSMenuItem) {
        copyDiagnostics()
    }

    func copyDiagnostics() {
        Diagnostics.copyToPasteboard(settings: settings, statusItem: statusItemDiagnostics())
    }

    /// Status item geometry for «Скопировать диагностику».
    func statusItemDiagnostics() -> [String: Any] {
        let window = statusItem.button?.window
        return [
            "isVisible": statusItem.isVisible,
            "autosaveName": statusItem.autosaveName ?? "",
            "hasButtonWindow": window != nil,
            "windowFrame": Diagnostics.rect(window?.frame),
            "occlusionVisible": window.map { $0.occlusionState.contains(.visible) } ?? false,
            "screen": window?.screen?.localizedName ?? "",
        ]
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings?()
    }

    @objc private func showAbout(_ sender: NSMenuItem) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Sugrob",
            .applicationVersion: SnowCore.version,
        ])
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
