import AppKit

/// Transparent, click-through, borderless window covering one whole screen.
@MainActor
final class OverlayWindow: NSWindow {
    convenience init(screen: NSScreen) {
        // The non-`screen:` initializer takes the rect in Cocoa global coordinates,
        // which is exactly what `screen.frame` is.
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // `.statusBar` (25) sits above normal and floating windows, the Dock (20) and the
        // menu bar (24), so snow is visible over everything that can carry a drift.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        isMovable = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise push the window out from under the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
