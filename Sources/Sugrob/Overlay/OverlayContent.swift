import AppKit

/// A view filling one overlay window. The Metal renderer plugs in by conforming to this.
@MainActor
protocol OverlayContent: NSView {
    /// Latest surfaces for `screen`, front to back, in screen-local y-down coordinates.
    func update(surfaces: [TrackedSurface], screen: NSScreen)
    /// Pause hides the snow; the window tracker keeps running.
    func setPaused(_ paused: Bool)
}

extension OverlayContent {
    func setPaused(_ paused: Bool) {
        isHidden = paused
    }
}
