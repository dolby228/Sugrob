import AppKit
import ApplicationServices
import os

private let log = Logger(subsystem: "dev.sugrob", category: "tracker")

/// Finds the Dock tile row on each screen.
///
/// The reserved strip (`screen.frame` vs `screen.visibleFrame`) only says which edge the
/// Dock is on; the tiles themselves are usually much narrower. Sources, best first:
/// 1. The union of the Dock's `AXList` elements (or of its `AXDockItem`s) lying in the
///    strip, padded to the Dock glass. Needs Accessibility, which is requested only from
///    the settings window or the status menu («Точный размер Dock…»).
/// 2. A Dock-owned window at Dock level that lies in the strip and is smaller than it.
/// 3. An estimate from the `com.apple.dock` preferences and the running apps (see
///    `DockPreferences`).
/// 4. 55% of the strip, centered.
/// The result is always clipped to the strip.
///
/// Nothing is reported while the Dock is not shown: no reserved strip (auto-hide),
/// `autohide` set in the preferences, or a full-screen Space (see `fullScreenReason`).
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
    /// The AX tile frames cover the icons; the Dock glass reaches this much further out.
    static let accessibilityPadding: CGFloat = 5
    /// How deep the AX tree of the Dock is searched, and how many elements at most.
    static let accessibilityMaxDepth = 4
    static let accessibilityMaxElements = 400
    /// After an app launches or quits the Dock animates its tiles: re-read after these delays.
    static let launchRefreshDelays: [TimeInterval] = [0.3, 1.3]
    /// The menu bar is a window of this owner at the main menu level.
    static let menuBarOwner = "Window Server"
    static let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
    /// Slack for comparing window edges with screen edges, in points.
    static let edgeTolerance: CGFloat = 2

    /// Why a screen is taken for a full-screen Space.
    enum FullScreenReason: String, Equatable {
        /// The front-most window spans the screen from the menu bar (or notch) down.
        case frontWindow = "front window fills the screen"
        /// No menu bar on the screen and a window lies where the Dock would be.
        case noMenuBar = "no menu bar and a window under the dock"
    }

    private(set) var dockPID: pid_t?
    private var lastSlowRefresh: TimeInterval = -.infinity
    private var preferences: DockPreferences?
    /// Dock tile frames read via Accessibility, CG global.
    private(set) var accessibilityTiles: AccessibilityTiles?
    private var observingWorkspace = false
    private var pendingRefreshes: [DispatchWorkItem] = []
    private var loggedDockWindows: [WindowListEntry] = []
    private var loggedSources: [Int: Source] = [:]
    private var loggedFullScreen: [Int: FullScreenReason] = [:]

    /// Dock frames for every screen where the Dock is shown. `list` is the raw window list,
    /// `windows` the ordinary (layer 0) windows front to back.
    func locate(in list: [WindowListEntry], windows: [TrackedWindow]) -> Result {
        observeWorkspaceIfNeeded()
        refreshSlowSources()
        let dockWindows = list.filter { isDockOwned($0) }
        logDockWindows(dockWindows)

        var result = Result()
        if preferences?.autohide == true {
            logSources([:])
            return result
        }
        var sources: [Int: Source] = [:]
        var fullScreen: [Int: FullScreenReason] = [:]
        defer { logFullScreen(fullScreen) }
        let primaryHeight = Coordinates.primaryScreenHeight
        for screen in NSScreen.screens {
            guard let reserved = Self.reservedStrip(for: screen) else { continue }
            let (strip, edge) = reserved
            let screenFrame = screen.frame
            let id = WindowTracker.dockSurfaceID(for: screen)
            let screenCG = Coordinates.cgRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)

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
            if let accessibilityTiles,
               let tiles = Self.accessibilityFrame(
                   accessibilityTiles,
                   screenFrame: screenFrame,
                   primaryHeight: primaryHeight,
                   strip: strip,
                   edge: edge
               ),
               let fitted = Self.fit(tiles, in: strip) {
                frame = fitted
                source = .accessibility
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
            guard let frame else { continue }
            let dockCG = Coordinates.cgRect(fromScreenLocal: frame, screenFrame: screenFrame, primaryHeight: primaryHeight)
            if let reason = Self.fullScreenReason(
                screenCG: screenCG,
                topInset: Self.topInset(of: screen),
                dockCG: dockCG,
                list: list,
                windows: windows
            ) {
                fullScreen[id] = reason
                continue
            }
            result.frames[id] = frame
            sources[id] = source
        }

        logSources(sources)
        return result
    }

    /// Non-nil when the screen shows a full-screen Space, where the Dock is hidden.
    /// All rects are CG global; `windows` are the ordinary (layer 0) windows front to back.
    ///
    /// On a notched Mac a full-screen app starts below the notch (y = menu bar height), so
    /// "the front window covers the whole screen" is not enough. Either:
    /// - the front-most window on the screen spans its full width, reaches its bottom and
    ///   starts no lower than the top inset; or
    /// - the screen has no menu bar window and some window covers the Dock rect. The menu
    ///   bar alone is not proof: with "automatically hide the menu bar" it is absent on the
    ///   desktop too, while the Dock is still shown above the windows.
    static func fullScreenReason(
        screenCG: CGRect,
        topInset: CGFloat,
        dockCG: CGRect,
        list: [WindowListEntry],
        windows: [TrackedWindow]
    ) -> FullScreenReason? {
        let tolerance = edgeTolerance
        if let front = windows.first(where: { $0.frame.intersects(screenCG) }) {
            let frame = front.frame
            if frame.minX <= screenCG.minX + tolerance,
               frame.maxX >= screenCG.maxX - tolerance,
               frame.maxY >= screenCG.maxY - tolerance,
               frame.minY <= screenCG.minY + topInset + tolerance {
                return .frontWindow
            }
        }
        if !hasMenuBar(screenCG: screenCG, topInset: topInset, list: list),
           windows.contains(where: { $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(dockCG) }) {
            return .noMenuBar
        }
        return nil
    }

    /// A menu bar window along the top of the screen is on screen. The height check is
    /// lenient on purpose: a missed menu bar only matters together with a window under the
    /// Dock, and the auto-hidden bar may report a different inset than it is tall.
    static func hasMenuBar(screenCG: CGRect, topInset: CGFloat, list: [WindowListEntry]) -> Bool {
        let tolerance = edgeTolerance
        let maxHeight = max(topInset + 4, 60)
        return list.contains { entry in
            entry.ownerName == menuBarOwner
                && entry.layer == menuBarLevel
                && abs(entry.bounds.minY - screenCG.minY) <= tolerance
                && abs(entry.bounds.minX - screenCG.minX) <= tolerance
                && abs(entry.bounds.width - screenCG.width) <= tolerance
                && entry.bounds.height > 0 && entry.bounds.height <= maxHeight
        }
    }

    /// Menu bar height of the screen, or the notch's safe area when the bar is hidden.
    static func topInset(of screen: NSScreen) -> CGFloat {
        max(0, screen.frame.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top)
    }

    private func logFullScreen(_ fullScreen: [Int: FullScreenReason]) {
        guard fullScreen != loggedFullScreen else { return }
        for (id, reason) in fullScreen where loggedFullScreen[id] != reason {
            log.debug("dock \(id) hidden, full-screen space: \(reason.rawValue, privacy: .public)")
        }
        for id in loggedFullScreen.keys where fullScreen[id] == nil {
            log.debug("dock \(id) left the full-screen space")
        }
        loggedFullScreen = fullScreen
    }

    private func logSources(_ sources: [Int: Source]) {
        guard sources != loggedSources else { return }
        loggedSources = sources
        if sources.isEmpty {
            log.debug("dock hidden on every screen")
        }
        for (id, source) in sources {
            log.debug("dock \(id) located from \(source.rawValue, privacy: .public)")
        }
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

        var tiles: AccessibilityTiles?
        if let pid = dockPID, AXIsProcessTrusted() {
            tiles = Self.readAccessibilityTiles(dockPID: pid)
        }
        if tiles != accessibilityTiles {
            accessibilityTiles = tiles
            log.debug("dock accessibility tiles \(String(describing: tiles), privacy: .public)")
        }
    }

    /// Makes the next poll re-read the slow sources.
    func invalidateSlowSources() {
        lastSlowRefresh = -.infinity
    }

    /// Tiles appear and disappear as apps launch and quit; the Dock animates the change,
    /// so the frame is re-read shortly after and once more when the animation is over.
    private func observeWorkspaceIfNeeded() {
        guard !observingWorkspace else { return }
        observingWorkspace = true
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.scheduleRefreshes()
                }
            }
        }
    }

    /// Debounced: a burst of launches restarts the delays.
    private func scheduleRefreshes() {
        for work in pendingRefreshes {
            work.cancel()
        }
        pendingRefreshes = Self.launchRefreshDelays.map { delay in
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    self?.invalidateSlowSources()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            return work
        }
    }

    // MARK: Accessibility

    /// Dock tile frames in CG global coordinates (AX uses the same top-left, y-down space).
    struct AccessibilityTiles: Equatable, CustomStringConvertible {
        /// Every `AXList` of the Dock; normally one, the tile row.
        var lists: [CGRect] = []
        /// Every `AXDockItem`, for when the lists are missing or not usable.
        var items: [CGRect] = []

        var description: String {
            "lists \(lists) items \(items.count) union \(String(describing: DockLocator.union(items)))"
        }
    }

    /// The Dock rect on one screen from the AX tiles, screen-local, padded to the glass:
    /// the union of the lists lying in the strip, or of the items if the lists are missing
    /// or as long as the strip (then they say nothing about the tiles).
    static func accessibilityFrame(
        _ tiles: AccessibilityTiles,
        screenFrame: CGRect,
        primaryHeight: CGFloat,
        strip: CGRect,
        edge: Edge
    ) -> CGRect? {
        func inStrip(_ frames: [CGRect]) -> CGRect? {
            let local = frames
                .map { Coordinates.screenLocal(fromCG: $0, screenFrame: screenFrame, primaryHeight: primaryHeight) }
                .filter { liesInStrip($0, strip: strip, edge: edge) }
            return union(local)
        }
        let padding = accessibilityPadding
        if let lists = inStrip(tiles.lists), isShorterThanStrip(lists, strip: strip, edge: edge) {
            return lists.insetBy(dx: -padding, dy: -padding)
        }
        if let items = inStrip(tiles.items) {
            return items.insetBy(dx: -padding, dy: -padding)
        }
        return nil
    }

    nonisolated static func union(_ frames: [CGRect]) -> CGRect? {
        guard var result = frames.first else { return nil }
        for frame in frames.dropFirst() {
            result = result.union(frame)
        }
        return result
    }

    /// Walks the Dock's AX tree (a few levels deep: on newer macOS the list can be nested)
    /// and collects the frames of every `AXList` and `AXDockItem`. Nil when nothing is found.
    /// Needs Accessibility; never asks for it.
    static func readAccessibilityTiles(dockPID: pid_t) -> AccessibilityTiles? {
        let app = AXUIElementCreateApplication(dockPID)
        var tiles = AccessibilityTiles()
        var budget = accessibilityMaxElements
        collect(app, depth: 0, into: &tiles, budget: &budget)
        return tiles.lists.isEmpty && tiles.items.isEmpty ? nil : tiles
    }

    private static func collect(_ element: AXUIElement, depth: Int, into tiles: inout AccessibilityTiles, budget: inout Int) {
        guard budget > 0 else { return }
        budget -= 1
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        if depth > 0 {
            switch stringAttribute("AXRole", of: element) {
            case "AXList":
                if let frame = frame(of: element) { tiles.lists.append(frame) }
            case "AXDockItem":
                // Items have no tiles inside.
                if let frame = frame(of: element) { tiles.items.append(frame) }
                return
            default:
                break
            }
        }
        guard depth < accessibilityMaxDepth else { return }
        var childrenValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &childrenValue) == .success,
            let children = childrenValue as? [AXUIElement]
        else { return }
        for child in children {
            collect(child, depth: depth + 1, into: &tiles, budget: &budget)
        }
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// `AXPosition` + `AXSize`, nil if missing or empty.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeValue) == .success,
            let positionRef = positionValue, let sizeRef = sizeValue,
            CFGetTypeID(positionRef) == AXValueGetTypeID(),
            CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        // The type ids were checked above, so these casts cannot fail.
        guard
            AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
            AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
            size.width > 0, size.height > 0
        else { return nil }
        return CGRect(origin: origin, size: size)
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
