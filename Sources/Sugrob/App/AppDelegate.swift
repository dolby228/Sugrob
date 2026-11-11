import AppKit
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings?
    private var menuBar: MenuBarController?
    private var controls: FallbackControls?
    private var dock: DockPresence?
    private var tracker: WindowTracker?
    private var overlay: OverlayController?
    private var power: PowerMonitor?
    private var mouse: MouseInput?
    /// Nil when Metal is unavailable; overlays then fall back to `DebugOverlayView`.
    private var pipelines: RenderPipelines?

    /// `main.swift` top-level code is nonisolated, so the delegate must be creatable there.
    /// Everything else happens in `applicationDidFinishLaunching` on the main actor.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Sugrob \(SnowCore.version, privacy: .public) started")

        let settings = Settings()
        self.settings = settings

        let power = PowerMonitor()
        self.power = power
        pipelines = RenderPipelines.makeDefault()

        let overlay = OverlayController { [weak self] screen in
            guard let self else { return DebugOverlayView(frame: .zero) }
            return self.makeContent(for: screen)
        }
        self.overlay = overlay

        AccessibilityAccess.startWatching()
        let tracker = WindowTracker()
        tracker.excludedWindowIDs = { [weak overlay] in
            overlay?.windowIDs ?? []
        }
        self.tracker = tracker

        let menuBar = MenuBarController(settings: settings)
        self.menuBar = menuBar
        let controls = FallbackControls(settings: settings, menuBar: menuBar)
        self.controls = controls
        let dock = DockPresence(settings: settings)
        dock.onOpenSettings = { [weak controls] in
            controls?.showSettings()
        }
        dock.apply()
        self.dock = dock

        let mouse = MouseInput(settings: settings) { [weak self] in
            self?.snowWorlds() ?? []
        }
        self.mouse = mouse
        mouse.onCaptureChange = { [weak self] screen in
            self?.overlay?.setMouseCapture(displayID: screen?.displayID)
        }
        mouse.isCaptureBlocked = { [weak self] screen, point in
            guard let view = self?.snowView(for: screen) else { return true }
            return view.blocksCapture(at: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
        }

        tracker.onUpdate = { [weak self] _, _ in
            self?.pushSurfaces()
        }
        overlay.onScreensChanged = { [weak self] in
            self?.pushSurfaces()
        }
        settings.addObserver { [weak self] key in
            self?.settingsChanged(key)
        }
        power.onChange = { [weak self] profile in
            self?.applyPower(profile)
        }

        overlay.start()
        overlay.setPaused(settings.isPaused)
        applyDebugOutlines()
        // Pause only hides the content; tracking keeps running so snow resumes in place.
        tracker.start()
        pushSurfaces()
        mouse.start()
        controls.start()
    }

    /// Opening Sugrob.app again while it runs: the status item may be hidden by the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controls?.showSettings()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        dock?.dockMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controls?.stop()
        mouse?.stop()
        tracker?.stop()
        overlay?.stop()
    }

    private var debugOutlinesEnabled: Bool {
        DebugOverlayView.environmentForcesOutlines || (settings?.showDebugOutlines ?? false)
    }

    /// A Metal snow view when possible, otherwise the outline-only debug view.
    private func makeContent(for screen: NSScreen) -> any OverlayContent {
        let frame = NSRect(origin: .zero, size: screen.frame.size)
        if let pipelines, let settings {
            let view = SnowView(frame: frame, pipelines: pipelines, settings: settings)
            view.applyPower(power?.profile ?? .normal)
            view.showsDebugOutlines = debugOutlinesEnabled
            view.onMouseEvent = { [weak self] event in
                self?.mouse?.receive(event)
            }
            return view
        }
        let view = DebugOverlayView(frame: frame)
        view.showsOutlines = debugOutlinesEnabled
        return view
    }

    private func settingsChanged(_ key: Settings.Key) {
        guard let settings else { return }
        switch key {
        case .isPaused:
            overlay?.setPaused(settings.isPaused)
            if settings.isPaused { mouse?.cancel() }
        case .showDebugOutlines:
            applyDebugOutlines()
        case .tool:
            mouse?.toolChanged()
        case .showInDock:
            // Switching to accessory deactivates the app and can hide the settings window.
            let settingsVisible = controls?.isSettingsVisible ?? false
            dock?.apply()
            if settingsVisible {
                DispatchQueue.main.async { [weak self] in
                    self?.controls?.showSettings()
                }
            }
        case .snowfall, .windX, .windY:
            // Snowfall and wind reach each SnowView through its WorldSettingsBinder.
            break
        }
    }

    private func applyDebugOutlines() {
        guard let overlay else { return }
        let enabled = debugOutlinesEnabled
        for entry in overlay.contents {
            if let snow = entry.content as? SnowView {
                snow.showsDebugOutlines = enabled
            } else if let debug = entry.content as? DebugOverlayView {
                debug.showsOutlines = enabled
            }
        }
    }

    private func applyPower(_ profile: PowerMonitor.Profile) {
        guard let overlay else { return }
        for entry in overlay.contents {
            (entry.content as? SnowView)?.applyPower(profile)
        }
    }

    /// The snow world of every screen that has a Metal view, for the mouse tools.
    private func snowWorlds() -> [(screen: NSScreen, world: SnowWorld)] {
        guard let overlay else { return [] }
        var result: [(screen: NSScreen, world: SnowWorld)] = []
        for entry in overlay.contents {
            if let view = entry.content as? SnowView {
                result.append((screen: entry.screen, world: view.world))
            }
        }
        return result
    }

    private func snowView(for screen: NSScreen) -> SnowView? {
        guard let overlay, let id = screen.displayID else { return nil }
        return overlay.contents.first { $0.screen.displayID == id }?.content as? SnowView
    }

    private func pushSurfaces() {
        guard let overlay, let tracker else { return }
        for entry in overlay.contents {
            entry.content.update(surfaces: tracker.surfaces(for: entry.screen), screen: entry.screen)
            entry.content.setCovered(tracker.isCoveredByPanel(entry.screen))
        }
    }
}
