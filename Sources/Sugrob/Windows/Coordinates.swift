import AppKit

/// Conversions between the three coordinate spaces the app deals with.
///
/// - **CG global**: origin at the top-left of the *primary* screen (`NSScreen.screens[0]`),
///   y grows down. `CGWindowListCopyWindowInfo` reports window bounds in this space.
/// - **Cocoa global**: origin at the bottom-left of the primary screen, y grows up.
///   `NSScreen.frame` and `NSWindow.frame` live here.
/// - **Screen-local y-down**: origin at the top-left of a given screen, y grows down.
///   This is what SnowCore and the overlay content views work with.
///
/// On multiple monitors the y axis of both global spaces is anchored to the primary screen,
/// so every conversion needs the primary screen height.
enum Coordinates {
    /// Height of the primary screen, the anchor of the CG <-> Cocoa flip.
    @MainActor
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    // MARK: CG global <-> Cocoa global

    /// `cocoaY = primaryHeight - cgY - height`.
    static func cocoaRect(fromCG rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    /// The flip is its own inverse: `cgY = primaryHeight - cocoaY - height`.
    static func cgRect(fromCocoa rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryHeight - rect.minY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaPoint(fromCG point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    static func cgPoint(fromCocoa point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: CG global <-> screen-local y-down

    /// Converts a CG global rect into the y-down space of the screen whose Cocoa frame is
    /// `screenFrame`.
    static func screenLocal(fromCG rect: CGRect, screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        let screenCG = cgRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)
        return rect.offsetBy(dx: -screenCG.minX, dy: -screenCG.minY)
    }

    static func cgRect(fromScreenLocal rect: CGRect, screenFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        let screenCG = cgRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)
        return rect.offsetBy(dx: screenCG.minX, dy: screenCG.minY)
    }

    static func screenLocal(fromCG point: CGPoint, screenFrame: CGRect, primaryHeight: CGFloat) -> CGPoint {
        let screenCG = cgRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)
        return CGPoint(x: point.x - screenCG.minX, y: point.y - screenCG.minY)
    }

    // MARK: Cocoa global <-> screen-local y-down

    static func screenLocal(fromCocoa rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func cocoaRect(fromScreenLocal rect: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + screenFrame.minX,
            y: screenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Mouse locations from `NSEvent.mouseLocation` are Cocoa global points.
    static func screenLocal(fromCocoa point: CGPoint, screenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - screenFrame.minX, y: screenFrame.maxY - point.y)
    }
}

extension NSScreen {
    /// Stable identifier of the physical display behind this screen.
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
