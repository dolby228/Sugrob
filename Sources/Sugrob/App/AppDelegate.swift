import AppKit
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: Settings?
    private var menuBar: MenuBarController?
    private var tracker: WindowTracker?
    private var overlay: OverlayController?
    private var power: PowerMonitor?
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

        let tracker = WindowTracker()
        self.tracker = tracker

        menuBar = MenuBarController(settings: settings)

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
    }

    func applicationWillTerminate(_ notification: Notification) {
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
        case .showDebugOutlines:
            applyDebugOutlines()
        case .snowfall, .windX, .windY, .tool:
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

    private func pushSurfaces() {
        guard let overlay, let tracker else { return }
        for entry in overlay.contents {
            entry.content.update(surfaces: tracker.surfaces(for: entry.screen), screen: entry.screen)
        }
    }
}
