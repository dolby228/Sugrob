import AppKit

/// Placeholder overlay content until the Metal renderer lands.
/// Draws nothing unless outlines are enabled; then strokes the top edge of every tracked
/// window and the Dock area in red, which makes coordinate bugs obvious.
@MainActor
final class DebugOverlayView: NSView, OverlayContent {
    /// `SUGROB_DEBUG_WINDOWS=1` forces outlines on regardless of the menu toggle.
    static let environmentForcesOutlines =
        ProcessInfo.processInfo.environment["SUGROB_DEBUG_WINDOWS"] == "1"

    var showsOutlines = false {
        didSet {
            if showsOutlines != oldValue { needsDisplay = true }
        }
    }

    private var surfaces: [TrackedSurface] = []

    // Screen-local y-down matches a flipped view whose bounds equal the screen size.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    func update(surfaces: [TrackedSurface], screen: NSScreen) {
        guard surfaces != self.surfaces else { return }
        self.surfaces = surfaces
        if showsOutlines { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsOutlines else { return }
        NSColor.systemRed.setStroke()

        for surface in surfaces {
            switch surface.kind {
            case .window:
                let frame = surface.frame
                let edge = NSBezierPath()
                edge.lineWidth = 3
                edge.move(to: NSPoint(x: frame.minX, y: frame.minY))
                edge.line(to: NSPoint(x: frame.maxX, y: frame.minY))
                edge.stroke()

                let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                outline.setLineDash([4, 4], count: 2, phase: 0)
                outline.stroke()
            case .dock:
                let outline = NSBezierPath(rect: surface.frame.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                outline.stroke()
            }
        }
    }
}
