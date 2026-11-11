import CoreGraphics
import Foundation

/// An on-screen window of another app, as reported by the window server.
struct TrackedWindow: Equatable, Sendable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    /// CG global coordinates: origin top-left of the primary screen, y grows down.
    let frame: CGRect
}

/// Change of a tracked window between two polls.
enum WindowEvent: Equatable, Sendable {
    case added(TrackedWindow)
    case moved(TrackedWindow, from: CGRect)
    case resized(TrackedWindow, from: CGRect)
    case removed(CGWindowID)
}

/// Something snow can settle on, expressed for a single screen.
struct TrackedSurface: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case window
        case dock
    }

    /// Window surfaces use their `CGWindowID`; the Dock uses a negative synthetic id.
    let id: Int
    /// Screen-local coordinates: origin top-left of the screen, y grows down (SnowCore space).
    let frame: CGRect
    let kind: Kind
}
