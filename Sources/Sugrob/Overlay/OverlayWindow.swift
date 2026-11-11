import AppKit

/// Transparent, borderless window covering one whole screen. Click-through by default;
/// `MouseInput` makes it take the mouse only while the snow is being worked.
///
/// A non-activating panel: a click on it never activates Sugrob, so the app the user works
/// in keeps its focus and key window.
@MainActor
final class OverlayWindow: NSPanel {
    convenience init(screen: NSScreen) {
        // The non-`screen:` initializer takes the rect in Cocoa global coordinates,
        // which is exactly what `screen.frame` is.
        self.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        // Panels hide on deactivation by default; Sugrob is practically never active.
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
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
