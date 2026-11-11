import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

/// Ways to control Sugrob besides the status item, which can be hidden by the notch:
/// the settings window (on reopen, on first launch, from the menu).
@MainActor
final class FallbackControls {
    static let welcomeMessage =
        "Снежинка в строке меню — управление. Если её не видно (закрыта вырезом экрана), откройте Sugrob ещё раз или нажмите ⌥⌘,"

    private static let didShowWelcomeKey = "didShowWelcome"

    private let settings: Settings
    private let menuBar: MenuBarController
    private let defaults: UserDefaults
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
    }

    func start() {
        if !defaults.bool(forKey: Self.didShowWelcomeKey) {
            defaults.set(true, forKey: Self.didShowWelcomeKey)
            log.info("first launch, showing welcome")
            showSettings(message: Self.welcomeMessage)
        }
    }

    func stop() {}

    func showSettings(message: String? = nil) {
        settingsWindow.show(message: message)
    }
}
