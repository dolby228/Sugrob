import ApplicationServices
import CoreGraphics
import Foundation

/// Reads the Dock tile frames through Accessibility, off the main thread.
///
/// AX calls are synchronous IPC to the Dock and can block for a long time while the Dock
/// is busy, so the walk runs on its own serial queue (AXUIElement is thread-safe) and only
/// the result is handed back to the main thread. One element costs one
/// `AXUIElementCopyMultipleAttributeValues` call (role, position, size and children at
/// once). The children of an `AXList` whose own frame already gives the tile row are not
/// visited. The whole walk has a deadline; the first `.cannotComplete` aborts it.
/// A failed walk reports the error so the caller keeps the previous frame.
enum DockAccessibility {
    /// A reserved Dock strip in CG global coordinates (y down), to tell whether a list
    /// frame is usable on its own.
    struct Strip: Equatable {
        var rect: CGRect
        var edge: DockLocator.Edge
    }

    enum Failure: Equatable, CustomStringConvertible {
        case error(AXError)
        case deadline

        var description: String {
            switch self {
            case .error(let error): return "AXError \(error.rawValue)"
            case .deadline: return "deadline of \(DockAccessibility.walkDeadline)s exceeded"
            }
        }
    }

    struct Outcome {
        /// Nil when the walk succeeded but found no lists or items.
        var tiles: DockLocator.AccessibilityTiles?
        /// Set when the walk was aborted; `tiles` is then meaningless.
        var failure: Failure?
        /// Elements visited and how long the walk took, for diagnostics.
        var elements: Int
        var duration: TimeInterval
    }

    /// Total time one walk may take.
    static let walkDeadline: TimeInterval = 0.3
    /// Per-call messaging timeout (shortened to what is left of the deadline).
    static let messagingTimeout: TimeInterval = 0.25
    /// How deep the AX tree of the Dock is searched, and how many elements at most.
    static let maxDepth = 4
    static let maxElements = 400

    static let queue = DispatchQueue(label: "dev.sugrob.dock-accessibility", qos: .utility)

    private static let attributes = ["AXRole", "AXPosition", "AXSize", "AXChildren"] as CFArray

    /// Walks the Dock's AX tree (a few levels deep: on newer macOS the list can be nested)
    /// and collects the frames of every `AXList` and `AXDockItem`. Never asks for access.
    /// Blocking: call it on `queue`.
    static func walk(dockPID: pid_t, strips: [Strip]) -> Outcome {
        let start = ProcessInfo.processInfo.systemUptime
        var walker = Walker(strips: strips, deadline: start + walkDeadline)
        walker.visit(AXUIElementCreateApplication(dockPID), depth: 0)
        let tiles = walker.tiles.lists.isEmpty && walker.tiles.items.isEmpty ? nil : walker.tiles
        return Outcome(
            tiles: tiles,
            failure: walker.failure,
            elements: maxElements - walker.budget,
            duration: ProcessInfo.processInfo.systemUptime - start
        )
    }

    /// A list frame that on its own lies in a strip and is shorter than it: the tile row,
    /// so its items need not be read.
    static func isUsableList(_ frame: CGRect, strips: [Strip]) -> Bool {
        strips.contains { strip in
            DockLocator.liesInStrip(frame, strip: strip.rect, edge: strip.edge)
                && DockLocator.isShorterThanStrip(frame, strip: strip.rect, edge: strip.edge)
        }
    }

    private struct Walker {
        let strips: [Strip]
        let deadline: TimeInterval
        var tiles = DockLocator.AccessibilityTiles()
        var budget = DockAccessibility.maxElements
        var failure: Failure?

        mutating func visit(_ element: AXUIElement, depth: Int) {
            guard failure == nil, budget > 0 else { return }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                failure = .deadline
                return
            }
            budget -= 1
            let timeout = max(0.02, min(DockAccessibility.messagingTimeout, remaining))
            _ = AXUIElementSetMessagingTimeout(element, Float(timeout))

            var valuesRef: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, DockAccessibility.attributes, [], &valuesRef)
            guard error == .success, let values = valuesRef as? [AnyObject], values.count == 4 else {
                // The app element must answer; a vanished child is skipped. A busy Dock
                // (`.cannotComplete`) aborts the whole walk.
                if depth == 0 || error == .cannotComplete {
                    failure = .error(error == .success ? .failure : error)
                }
                return
            }

            var descend = depth < DockAccessibility.maxDepth
            if depth > 0 {
                switch values[0] as? String {
                case "AXList":
                    if let frame = DockAccessibility.frame(position: values[1], size: values[2]) {
                        tiles.lists.append(frame)
                        // The list already gives the tile row: its items add nothing.
                        if DockAccessibility.isUsableList(frame, strips: strips) {
                            descend = false
                        }
                    }
                case "AXDockItem":
                    if let frame = DockAccessibility.frame(position: values[1], size: values[2]) {
                        tiles.items.append(frame)
                    }
                    // Items have no tiles inside.
                    descend = false
                default:
                    break
                }
            }
            guard descend, let children = values[3] as? [AXUIElement] else { return }
            for child in children {
                visit(child, depth: depth + 1)
                if failure != nil { return }
            }
        }
    }

    /// `AXPosition` + `AXSize` values, nil if missing (an `.axError` value) or empty.
    private static func frame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard
            CFGetTypeID(position) == AXValueGetTypeID(),
            CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        // The type ids were checked above, so these casts cannot fail.
        let positionValue = position as! AXValue
        let sizeValue = size as! AXValue
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard
            AXValueGetType(positionValue) == .cgPoint,
            AXValueGetType(sizeValue) == .cgSize,
            AXValueGetValue(positionValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue, .cgSize, &extent),
            extent.width > 0, extent.height > 0
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
