import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "dev.sugrob", category: "tracker")

/// Finds the Dock tile row on each screen.
///
/// The reserved strip (`screen.frame` vs `screen.visibleFrame`) only says which edge the
/// Dock is on; the tiles themselves are usually much narrower. Sources, best first:
/// 1. The Dock's `AXList` element, if Accessibility is already granted (never prompted).
/// 2. A Dock-owned window at Dock level that lies in the strip and is smaller than it.
/// 3. An estimate from the `com.apple.dock` preferences (tile size and tile count).
/// 4. 55% of the strip, centered.
/// The result is always clipped to the strip.
@MainActor
final class DockLocator {
    struct Result: Equatable {
        /// Screen-local y-down Dock frames keyed by `WindowTracker.dockSurfaceID(for:)`.
        var frames: [Int: CGRect] = [:]
        /// Dock-owned windows at Dock level lying in a reserved strip (the tile window).
        var windowIDs: Set<CGWindowID> = []
    }

    enum Edge: Equatable {
        case bottom, left, right
    }

    enum Source: String {
        case accessibility, window, preferences, guess
    }

    static let bundleID = "com.apple.dock"
    static let ownerName = "Dock"
    static let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
    /// Accessibility, preferences and the Dock pid are re-read at most this often.
    static let slowRefreshInterval: TimeInterval = 1
    /// Share of the strip used when nothing better is known.
    static let guessedShare: CGFloat = 0.55

    private(set) var dockPID: pid_t?
    private var lastSlowRefresh: TimeInterval = -.infinity
    private var preferences: DockPreferences?
    /// CG global frame of the Dock tile list read via Accessibility.
    private var accessibilityFrame: CGRect?
    private var loggedDockWindows: [WindowListEntry] = []
    private var loggedSources: [Int: Source] = [:]

    /// Dock frames for every screen with a reserved strip. `list` is the raw window list.
    func locate(in list: [WindowListEntry]) -> Result {
        refreshSlowSources()
        let dockWindows = list.filter { isDockOwned($0) }
        logDockWindows(dockWindows)

        var result = Result()
        var sources: [Int: Source] = [:]
        let primaryHeight = Coordinates.primaryScreenHeight
        for screen in NSScreen.screens {
            guard let reserved = Self.reservedStrip(for: screen) else { continue }
            let (strip, edge) = reserved
            let screenFrame = screen.frame
            let id = WindowTracker.dockSurfaceID(for: screen)

            // Dock-level windows of the Dock inside the strip; the best one is the tile row.
            var tileWindow: CGRect?
            var bestOverlap: CGFloat = 0
            for entry in dockWindows where entry.layer == Self.dockLevel && entry.alpha > 0 {
                let local = Coordinates.screenLocal(
                    fromCG: entry.bounds,
                    screenFrame: screenFrame,
                    primaryHeight: primaryHeight
                )
                guard Self.liesInStrip(local, strip: strip, edge: edge) else { continue }
                result.windowIDs.insert(entry.id)
                // A window as long as the strip (or the whole screen) says nothing about the tiles.
                guard Self.isShorterThanStrip(local, strip: strip, edge: edge) else { continue }
                let overlap = local.intersection(strip)
                let area = overlap.width * overlap.height
                if area > bestOverlap {
                    bestOverlap = area
                    tileWindow = local
                }
            }

            var frame: CGRect?
            var source = Source.guess
            if let accessibilityFrame {
                let local = Coordinates.screenLocal(
                    fromCG: accessibilityFrame,
                    screenFrame: screenFrame,
                    primaryHeight: primaryHeight
                )
                if Self.liesInStrip(local, strip: strip, edge: edge), let fitted = Self.fit(local, in: strip) {
                    frame = fitted
                    source = .accessibility
                }
            }
            if frame == nil, let tileWindow, let fitted = Self.fit(tileWindow, in: strip) {
                frame = fitted
                source = .window
            }
            if frame == nil, let preferences {
                frame = Self.centered(length: preferences.estimatedLength, in: strip, edge: edge)
                source = .preferences
            }
            if frame == nil {
                let length = (edge == .bottom ? strip.width : strip.height) * Self.guessedShare
                frame = Self.centered(length: length, in: strip, edge: edge)
                source = .guess
            }
            if let frame {
                result.frames[id] = frame
                sources[id] = source
            }
        }

        if sources != loggedSources {
            loggedSources = sources
            for (id, source) in sources {
                log.debug("dock \(id) located from \(source.rawValue, privacy: .public)")
            }
        }
        return result
    }

    func isDockOwned(_ entry: WindowListEntry) -> Bool {
        if let dockPID, entry.ownerPID == dockPID { return true }
        return entry.ownerName == Self.ownerName
    }

    // MARK: Geometry

    /// The strip the Dock reserves, in screen-local y-down coordinates.
    /// The top inset is the menu bar and is ignored.
    static func reservedStrip(for screen: NSScreen) -> (CGRect, Edge)? {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let bottom = visible.minY - frame.minY
        let left = visible.minX - frame.minX
        let right = frame.maxX - visible.maxX
        let top = frame.maxY - visible.maxY
        let minimum = WindowTracker.minimumDockInset

        if bottom >= minimum {
            return (CGRect(x: 0, y: frame.height - bottom, width: frame.width, height: bottom), .bottom)
        }
        if left >= minimum {
            return (CGRect(x: 0, y: top, width: left, height: visible.height), .left)
        }
        if right >= minimum {
            return (CGRect(x: frame.width - right, y: top, width: right, height: visible.height), .right)
        }
        return nil
    }

    /// At least half of the strip's thickness is covered by `rect`.
    static func liesInStrip(_ rect: CGRect, strip: CGRect, edge: Edge) -> Bool {
        let overlap = rect.intersection(strip)
        guard !overlap.isNull, !overlap.isEmpty else { return false }
        switch edge {
        case .bottom: return overlap.height >= strip.height * 0.5
        case .left, .right: return overlap.width >= strip.width * 0.5
        }
    }

    static func isShorterThanStrip(_ rect: CGRect, strip: CGRect, edge: Edge) -> Bool {
        switch edge {
        case .bottom: return rect.width < strip.width * 0.98
        case .left, .right: return rect.height < strip.height * 0.98
        }
    }

    /// `rect` clipped to the strip, or nil if too little of it is left.
    static func fit(_ rect: CGRect, in strip: CGRect) -> CGRect? {
        let clipped = rect.intersection(strip)
        let minimum = WindowTracker.minimumDockInset
        guard !clipped.isNull, clipped.width >= minimum, clipped.height >= minimum else { return nil }
        return clipped
    }

    /// A Dock of `length` points centered along the strip, as thick as the strip.
    static func centered(length: CGFloat, in strip: CGRect, edge: Edge) -> CGRect? {
        guard length.isFinite, length > 0 else { return nil }
        switch edge {
        case .bottom:
            let width = min(length, strip.width)
            return CGRect(x: strip.midX - width / 2, y: strip.minY, width: width, height: strip.height)
        case .left, .right:
            let height = min(length, strip.height)
            return CGRect(x: strip.minX, y: strip.midY - height / 2, width: strip.width, height: height)
        }
    }

    // MARK: Slow sources

    private func refreshSlowSources() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSlowRefresh >= Self.slowRefreshInterval else { return }
        lastSlowRefresh = now

        if let pid = dockPID, NSRunningApplication(processIdentifier: pid)?.isTerminated == false {
            // Still the same Dock process.
        } else {
            dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
                .first?.processIdentifier
            let pid = dockPID.map { Int($0) } ?? -1
            log.debug("dock pid \(pid)")
        }

        let preferences = DockPreferences.read()
        if preferences != self.preferences {
            self.preferences = preferences
            log.debug("dock preferences \(String(describing: preferences), privacy: .public)")
        }

        var axFrame: CGRect?
        if let pid = dockPID, AXIsProcessTrusted() {
            axFrame = Self.readAccessibilityFrame(dockPID: pid)
        }
        if axFrame != accessibilityFrame {
            accessibilityFrame = axFrame
            log.debug("dock accessibility frame \(String(describing: axFrame), privacy: .public)")
        }
    }

    /// Frame of the Dock's tile list (`AXList`), in CG global coordinates (AX uses the
    /// same top-left, y-down space). Needs Accessibility; never asks for it.
    static func readAccessibilityFrame(dockPID: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(dockPID)
        _ = AXUIElementSetMessagingTimeout(app, 0.25)

        var childrenValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, "AXChildren" as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else { return nil }

        var best: CGRect?
        for child in children {
            var roleValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(child, "AXRole" as CFString, &roleValue) == .success,
                let role = roleValue as? String, role == "AXList"
            else { continue }

            var positionValue: CFTypeRef?
            var sizeValue: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(child, "AXPosition" as CFString, &positionValue) == .success,
                AXUIElementCopyAttributeValue(child, "AXSize" as CFString, &sizeValue) == .success,
                let positionRef = positionValue, let sizeRef = sizeValue,
                CFGetTypeID(positionRef) == AXValueGetTypeID(),
                CFGetTypeID(sizeRef) == AXValueGetTypeID()
            else { continue }

            var origin = CGPoint.zero
            var size = CGSize.zero
            // The type ids were checked above, so these casts cannot fail.
            guard
                AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
                AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
                size.width > 0, size.height > 0
            else { continue }

            let frame = CGRect(origin: origin, size: size)
            if best.map({ frame.width * frame.height > $0.width * $0.height }) ?? true {
                best = frame
            }
        }
        return best
    }

    private func logDockWindows(_ windows: [WindowListEntry]) {
        guard windows != loggedDockWindows else { return }
        loggedDockWindows = windows
        log.debug("dock owns \(windows.count) on-screen windows")
        for window in windows {
            log.debug("dock window \(Int(window.id)) layer \(window.layer) alpha \(window.alpha) \(String(describing: window.bounds), privacy: .public) name \(window.name ?? "-", privacy: .public)")
        }
    }
}

/// The parts of the `com.apple.dock` preferences that size the Dock.
struct DockPreferences: Equatable, CustomStringConvertible {
    var tileSize: CGFloat
    var persistentApps: Int
    var persistentOthers: Int
    /// Running regular apps that are not kept in the Dock; they get tiles too.
    var runningNotInDock: Int
    var showRecents: Bool
    var autohide: Bool
    var orientation: String

    /// Rough length of the tile row along its edge.
    var estimatedLength: CGFloat {
        // Recent apps show up to three tiles (running ones not kept in the Dock included).
        let recents = showRecents ? max(runningNotInDock, 3) : runningNotInDock
        // Finder + kept apps + running/recent apps + separator + folders/stacks + Trash.
        let separators = recents > 0 ? 2 : 1
        let slots = 1 + persistentApps + recents + persistentOthers + 1 + separators
        return CGFloat(slots) * (tileSize + 4) + 16
    }

    var description: String {
        "tile \(tileSize) apps \(persistentApps) others \(persistentOthers) running \(runningNotInDock) recents \(showRecents) autohide \(autohide) \(orientation)"
    }

    /// Nil when the Dock preferences cannot be read.
    static func read() -> DockPreferences? {
        guard let defaults = UserDefaults(suiteName: DockLocator.bundleID) else { return nil }
        let apps = defaults.array(forKey: "persistent-apps")
        let tileSize = defaults.object(forKey: "tilesize") as? NSNumber
        guard apps != nil || tileSize != nil else { return nil }

        var keptBundleIDs: Set<String> = ["com.apple.finder"]
        for case let entry as [String: Any] in apps ?? [] {
            if let data = entry["tile-data"] as? [String: Any], let id = data["bundle-identifier"] as? String {
                keptBundleIDs.insert(id)
            }
        }
        let running = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard let id = app.bundleIdentifier else { return true }
            return !keptBundleIDs.contains(id)
        }.count

        let size = CGFloat(tileSize?.doubleValue ?? 48)
        return DockPreferences(
            tileSize: size.isFinite && size > 0 ? size : 48,
            persistentApps: apps?.count ?? 0,
            persistentOthers: defaults.array(forKey: "persistent-others")?.count ?? 0,
            runningNotInDock: running,
            showRecents: (defaults.object(forKey: "show-recents") as? NSNumber)?.boolValue ?? true,
            autohide: defaults.bool(forKey: "autohide"),
            orientation: defaults.string(forKey: "orientation") ?? "bottom"
        )
    }
}
