import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

/// Ways to control Sugrob besides the status item, which can be hidden by the notch:
/// the settings window (on reopen, on first launch, from the menu) and global hotkeys.
@MainActor
final class FallbackControls {
    static let welcomeMessage =
        "Управление — снежинка в строке меню или иконка Sugrob в Dock (клик открывает это окно, правый клик — меню). Если снежинку закрыл вырез экрана, нажмите ⌃⌥⌘,"

    static let hiddenStatusItemMessage =
        "Значок Sugrob не виден в строке меню: скорее всего, его закрыл вырез экрана. Управлять снегом можно здесь. Открыть это окно снова: клик по иконке Sugrob в Dock или ⌃⌥⌘,"

    private static let didShowWelcomeKey = "didShowWelcome"

    private let settings: Settings
    private let menuBar: MenuBarController
    private let defaults: UserDefaults
    private var hotKeys: HotKeys?
    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(settings: settings)
        controller.onCopyDiagnostics = { [weak self] in
            self?.menuBar.copyDiagnostics()
        }
        return controller
    }()

    init(settings: Settings, menuBar: MenuBarController, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.menuBar = menuBar
        self.defaults = defaults
        menuBar.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        menuBar.onStatusItemHidden = { [weak self] reason in
            self?.statusItemHidden(reason)
        }
    }

    func start() {
        let hotKeys = HotKeys { [weak self] action in
            self?.perform(action)
        }
        hotKeys.register()
        self.hotKeys = hotKeys

        if !defaults.bool(forKey: Self.didShowWelcomeKey) {
            defaults.set(true, forKey: Self.didShowWelcomeKey)
            log.info("first launch, showing welcome")
            showSettings(message: Self.welcomeMessage)
        }
        menuBar.scheduleVisibilityCheck()
    }

    func stop() {
        hotKeys?.unregister()
        hotKeys = nil
    }

    var isSettingsVisible: Bool {
        settingsWindow.window?.isVisible ?? false
    }

    func showSettings(message: String? = nil) {
        settingsWindow.show(message: message)
    }

    private func statusItemHidden(_ reason: String) {
        if settingsWindow.isShowingMessage {
            log.info("status item hidden (\(reason, privacy: .public)), welcome already shown")
            return
        }
        log.info("status item hidden (\(reason, privacy: .public)), showing settings")
        showSettings(message: Self.hiddenStatusItemMessage)
    }

    private func perform(_ action: HotKeys.Action) {
        switch action {
        case .togglePause:
            settings.isPaused.toggle()
        case .openSettings:
            showSettings()
        case .clearAll:
            NotificationCenter.default.post(name: .sugrobClearAll, object: nil)
        case .quit:
            NSApp.terminate(nil)
        }
    }
}
