import AppKit
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "menu")

/// Status bar item with all user controls. Labels are in Russian.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    /// «Настройки…».
    var onOpenSettings: (() -> Void)?
    /// Called at most once per launch when the status item turns out not to be visible.
    /// The argument is a short reason for the log.
    var onStatusItemHidden: ((String) -> Void)?

    private var reportedHidden = false
    private var visibilityCheck: DispatchWorkItem?

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
        // Keeps a ⌘-drag position across launches.
        statusItem.autosaveName = "dev.sugrob.statusItem"

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: Visibility

    /// Checks a bit later whether the status item is actually visible: the menu bar lays
    /// out items asynchronously, and on a full menu bar a notched Mac hides them.
    func scheduleVisibilityCheck(after delay: TimeInterval = 2) {
        visibilityCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.checkVisibility()
            }
        }
        visibilityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        scheduleVisibilityCheck()
    }

    private func checkVisibility() {
        guard let reason = hiddenReason() else {
            log.debug("status item visible")
            return
        }
        log.notice("status item hidden: \(reason, privacy: .public)")
        guard !reportedHidden else { return }
        reportedHidden = true
        onStatusItemHidden?(reason)
    }

    /// Nil when the status item looks visible, otherwise why it is not.
    func hiddenReason() -> String? {
        guard statusItem.isVisible else { return "isVisible is false" }
        guard let window = statusItem.button?.window else { return "no button window" }
        if !window.occlusionState.contains(.visible) {
            return "button window is occluded"
        }
        let frame = window.frame
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else {
            return "button window \(frame) is off every screen"
        }
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea.map({ Self.global($0, on: screen) }),
              let right = screen.auxiliaryTopRightArea.map({ Self.global($0, on: screen) })
        else { return nil }
        // The notch is the gap between the two unobscured top areas.
        let notch = NSRect(
            x: left.maxX,
            y: min(left.minY, right.minY),
            width: right.minX - left.maxX,
            height: max(left.height, right.height)
        )
        if notch.width > 0, notch.intersects(frame) {
            return "button window \(frame) intersects the notch \(notch)"
        }
        // Status items live right of the notch; anything left of it is under the app menus.
        if frame.minX < right.minX - 1 {
            return "button window \(frame) is left of the notch \(notch)"
        }
        return nil
    }

    /// `auxiliaryTop*Area` should be in global coordinates; tolerate screen-local rects.
    private static func global(_ rect: NSRect, on screen: NSScreen) -> NSRect {
        if screen.frame.contains(rect) { return rect }
        return rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
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
            "hiddenReason": (hiddenReason() as Any?) ?? NSNull(),
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
