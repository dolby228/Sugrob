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

    /// `main.swift` top-level code is nonisolated, so the delegate must be creatable there.
    /// Everything else happens in `applicationDidFinishLaunching` on the main actor.
    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log.info("Sugrob \(SnowCore.version, privacy: .public) started")

        let settings = Settings()
        self.settings = settings

        let overlay = OverlayController { [weak self] _ in
            let view = DebugOverlayView(frame: .zero)
            view.showsOutlines = self?.debugOutlinesEnabled ?? DebugOverlayView.environmentForcesOutlines
            return view
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

    private func settingsChanged(_ key: Settings.Key) {
        guard let settings else { return }
        switch key {
        case .isPaused:
            overlay?.setPaused(settings.isPaused)
        case .showDebugOutlines:
            applyDebugOutlines()
        case .snowfall, .windX, .windY, .tool:
            break
        }
    }

    private func applyDebugOutlines() {
        guard let overlay else { return }
        let enabled = debugOutlinesEnabled
        for entry in overlay.contents {
            (entry.content as? DebugOverlayView)?.showsOutlines = enabled
        }
    }

    private func pushSurfaces() {
        guard let overlay, let tracker else { return }
        for entry in overlay.contents {
            entry.content.update(surfaces: tracker.surfaces(for: entry.screen), screen: entry.screen)
        }
    }
}
