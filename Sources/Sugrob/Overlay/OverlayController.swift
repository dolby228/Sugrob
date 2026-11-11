import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "overlay")

/// Keeps exactly one `OverlayWindow` per `NSScreen` and owns their content views.
/// Windows are created and destroyed as displays come and go.
@MainActor
final class OverlayController: NSObject {
    typealias ContentFactory = @MainActor (NSScreen) -> any OverlayContent

    private struct Entry {
        let window: OverlayWindow
        let content: any OverlayContent
        var screen: NSScreen
    }

    /// Called after windows were rebuilt for a new screen configuration.
    var onScreensChanged: (@MainActor () -> Void)?

    private let makeContent: ContentFactory
    private var entries: [CGDirectDisplayID: Entry] = [:]
    private(set) var isPaused = false
    /// Display whose overlay takes the mouse; every other overlay is click-through.
    private(set) var captureDisplay: CGDirectDisplayID?
    private var isStarted = false

    init(makeContent: @escaping ContentFactory) {
        self.makeContent = makeContent
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        syncWindows()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        for entry in entries.values {
            entry.window.orderOut(nil)
            entry.window.close()
        }
        entries.removeAll()
    }

    /// Window numbers of the overlay windows, which the window tracker must skip.
    var windowIDs: Set<CGWindowID> {
        Set(entries.values.compactMap { entry in
            let number = entry.window.windowNumber
            return number > 0 ? CGWindowID(number) : nil
        })
    }

    /// Every screen currently covered, with its content view.
    var contents: [(screen: NSScreen, content: any OverlayContent)] {
        entries.values.map { (screen: $0.screen, content: $0.content) }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        for entry in entries.values {
            entry.content.setPaused(paused)
        }
    }

    /// Lets the overlay of `displayID` receive the mouse, or none for nil.
    /// `ignoresMouseEvents` is always set explicitly: only the unset default hit-tests by
    /// alpha, an explicit `false` takes clicks on fully transparent pixels too.
    func setMouseCapture(displayID: CGDirectDisplayID?) {
        guard displayID != captureDisplay else { return }
        captureDisplay = displayID
        applyMouseCapture()
        if let displayID {
            log.debug("overlay of display \(Int(displayID)) takes the mouse")
        } else {
            log.debug("overlays are click-through")
        }
    }

    private func applyMouseCapture() {
        for (id, entry) in entries {
            entry.window.ignoresMouseEvents = id != captureDisplay
        }
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        syncWindows()
        onScreensChanged?()
    }

    /// Reuses windows of screens that are still attached, resizes them to the current
    /// frame, creates windows for new screens and closes windows of removed ones.
    private func syncWindows() {
        var seen = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)

            if var entry = entries[id] {
                entry.screen = screen
                entries[id] = entry
                if entry.window.frame != screen.frame {
                    entry.window.setFrame(screen.frame, display: true)
                    log.debug("resized overlay for display \(Int(id)) to \(String(describing: screen.frame), privacy: .public)")
                }
            } else {
                let window = OverlayWindow(screen: screen)
                let content = makeContent(screen)
                content.frame = NSRect(origin: .zero, size: screen.frame.size)
                content.autoresizingMask = [.width, .height]
                window.contentView = content
                content.setPaused(isPaused)
                window.orderFrontRegardless()
                entries[id] = Entry(window: window, content: content, screen: screen)
                log.debug("created overlay for display \(Int(id)) at \(String(describing: screen.frame), privacy: .public)")
            }
        }

        for (id, entry) in entries where !seen.contains(id) {
            entry.window.orderOut(nil)
            entry.window.close()
            entries[id] = nil
            log.debug("removed overlay for display \(Int(id))")
        }
        if let captureDisplay, !seen.contains(captureDisplay) {
            self.captureDisplay = nil
        }
        applyMouseCapture()
    }
}
