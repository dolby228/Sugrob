import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "tracker")

/// Polls the window server for on-screen windows of other apps and reports what changed.
///
/// Uses `CGWindowListCopyWindowInfo`, which needs no permissions for window bounds.
/// Only ordinary app windows are kept: layer 0, visible (alpha > 0), larger than 40x40
/// and not one of our overlays (they must never collect snow). Other windows of Sugrob,
/// such as the settings window, collect snow and occlude like any app window.
/// Windows above layer 0 but below the overlay (system panels, Spotlight, banners,
/// floating palettes) are kept separately as occluders: they never carry snow but hide
/// any drift behind them.
@MainActor
final class WindowTracker: NSObject {
    /// Called on the main thread after a poll that changed anything: the window list
    /// (including z-order) or the Dock area. `windows` is ordered front to back.
    var onUpdate: (@MainActor (_ windows: [TrackedWindow], _ events: [WindowEvent]) -> Void)?
    /// Window numbers of our overlay windows, skipped everywhere.
    var excludedWindowIDs: (@MainActor () -> Set<CGWindowID>)?

    /// Current windows, front to back, in CG global coordinates.
    private(set) var windows: [TrackedWindow] = []

    let interval: TimeInterval
    static let minimumSize = CGSize(width: 40, height: 40)
    /// Insets smaller than this (e.g. the sliver left by an auto-hidden Dock) are ignored.
    static let minimumDockInset: CGFloat = 8
    /// Layer of our overlay (`.statusBar`); windows at or above it are drawn over the snow anyway.
    static let overlayLayer = Int(CGWindowLevelForKey(.statusWindow))
    /// Owners of the menu bar and its extras, which never occlude drifts.
    static let ignoredOccluderOwners: Set<String> = ["Window Server", "SystemUIServer", "Control Center"]
    /// A window covering at least this share of a screen is a backdrop, not an occluder.
    static let fullScreenCoverage: CGFloat = 0.9
    /// Owners whose near full-screen panels (Launchpad / Apps, Mission Control, Spotlight)
    /// hide all snow on that screen. The Dock itself is matched by pid as well.
    static let coveringPanelOwners: Set<String> = [DockLocator.ownerName, "Spotlight"]
    /// Dock layers that hold its tiles and permanent transparent backdrops, never a panel.
    static let ignoredDockCoverLayers = 18...20
    /// A covering window must be at least this opaque.
    static let minimumCoverAlpha = 0.5
    /// Polls in a row a window must cover a screen before the snow there is hidden.
    static let coverPolls = 2
    /// A window that appears this soon after ⌥ changed (or while it is held) belongs to
    /// a modifier gesture (window tiling and the like), not to a full-screen panel.
    static let modifierGrace: TimeInterval = 0.5

    /// The window that hides the snow on one display, for logs and diagnostics.
    struct CoveringWindow: Equatable, Sendable {
        let id: CGWindowID
        let ownerName: String
        let layer: Int
        let alpha: Double
        /// CG global coordinates.
        let bounds: CGRect

        var summary: String {
            "\(id) \(ownerName) layer \(layer) alpha \(alpha) \(bounds)"
        }
    }

    private var timer: Timer?
    private var dockFrames: [Int: CGRect] = [:]
    /// System panels in front of all ordinary windows, front to back, CG global.
    private var occluders: [TrackedWindow] = []
    /// Displays hidden behind a full-screen system panel, with the window doing it.
    private(set) var coveredDisplays: [CGDirectDisplayID: CoveringWindow] = [:]
    /// Polls in a row each candidate window has covered a screen.
    private var coverStreaks: [CGWindowID: Int] = [:]
    /// Candidates that showed up with ⌥ and never count as panels.
    private var modifierWindowIDs: Set<CGWindowID> = []
    private var optionWasDown = false
    private var lastOptionChange: TimeInterval = -.infinity
    private let dockLocator = DockLocator()

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
        super.init()
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: interval,
            target: self,
            selector: #selector(tick(_:)),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = interval * 0.2
        // `.common` keeps polling while a menu is open or a window is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        log.debug("tracker started, interval \(self.interval, privacy: .public)s")
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        log.debug("tracker stopped")
    }

    @objc private func tick(_ timer: Timer) {
        poll()
    }

    /// Reads the window list once and fires `onUpdate` if something changed.
    func poll() {
        let excluded = excludedWindowIDs?() ?? []
        let list = Self.readWindowList().filter { !excluded.contains($0.id) }
        let current = Self.ordinaryWindows(in: list)
        let events = Self.diff(old: windows, new: current)
        let orderChanged = events.isEmpty && current.map(\.id) != windows.map(\.id)

        let dock = dockLocator.locate(in: list, windows: current)
        let docks = dock.frames
        let docksChanged = docks != dockFrames

        let panels = findOccluders(in: list, dockWindowIDs: dock.windowIDs)
        let panelsChanged = panels != occluders

        let covered = findCoveredDisplays(in: list, optionDown: NSEvent.modifierFlags.contains(.option))
        let coveredChanged = covered != coveredDisplays

        guard !events.isEmpty || orderChanged || docksChanged || panelsChanged || coveredChanged else { return }

        windows = current
        dockFrames = docks
        occluders = panels
        coveredDisplays = covered
        for event in events {
            Self.logEvent(event)
        }
        if docksChanged {
            log.debug("dock areas changed: \(String(describing: docks), privacy: .public)")
        }
        if panelsChanged {
            let summary = panels.map { "\($0.id) \($0.ownerName) \(String(describing: $0.frame))" }
                .joined(separator: ", ")
            log.debug("occluders: \(summary, privacy: .public)")
        }
        if coveredChanged {
            let summary = covered.sorted { $0.key < $1.key }
                .map { "display \($0.key): \($0.value.summary)" }
                .joined(separator: "; ")
            log.info("displays covered by a system panel: [\(summary, privacy: .public)]")
        }
        onUpdate?(current, events)
    }

    // MARK: Surfaces

    /// Surfaces visible on `screen`, front to back, in that screen's local y-down space.
    /// Occluders come first, then the Dock, because both are drawn above all normal windows.
    /// Window frames are not clipped to the screen; the consumer clips if needed.
    func surfaces(for screen: NSScreen) -> [TrackedSurface] {
        let primaryHeight = Coordinates.primaryScreenHeight
        let screenFrame = screen.frame
        let screenCG = Coordinates.cgRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)

        var result: [TrackedSurface] = []
        for panel in occluders where panel.frame.intersects(screenCG) {
            let local = Coordinates.screenLocal(
                fromCG: panel.frame,
                screenFrame: screenFrame,
                primaryHeight: primaryHeight
            )
            result.append(TrackedSurface(id: Int(panel.id), frame: local, kind: .occluder))
        }
        let dockID = Self.dockSurfaceID(for: screen)
        if let dock = dockFrames[dockID] {
            result.append(TrackedSurface(id: dockID, frame: dock, kind: .dock))
        }
        for window in windows where window.frame.intersects(screenCG) {
            let local = Coordinates.screenLocal(
                fromCG: window.frame,
                screenFrame: screenFrame,
                primaryHeight: primaryHeight
            )
            result.append(TrackedSurface(id: Int(window.id), frame: local, kind: .window))
        }
        return result
    }

    /// How the Dock was located (source per screen, AX state and frames, estimate inputs).
    var dockDiagnostics: [String: Any] { dockLocator.diagnostics }

    /// Synthetic negative id of the Dock surface on a screen; stable across polls.
    static func dockSurfaceID(for screen: NSScreen) -> Int {
        -(Int(screen.displayID ?? 0) + 1)
    }

    // MARK: Occluders

    /// Visible windows above layer 0 and below the overlay, front to back, except the
    /// menu bar, the Dock tile window and full-screen backdrops.
    private func findOccluders(in list: [WindowListEntry], dockWindowIDs: Set<CGWindowID>) -> [TrackedWindow] {
        let primaryHeight = Coordinates.primaryScreenHeight
        let screens = NSScreen.screens.map { Coordinates.cgRect(fromCocoa: $0.frame, primaryHeight: primaryHeight) }

        var result: [TrackedWindow] = []
        for entry in list {
            guard
                entry.layer > 0, entry.layer < Self.overlayLayer,
                entry.alpha > 0,
                entry.bounds.width > Self.minimumSize.width, entry.bounds.height > Self.minimumSize.height,
                !Self.ignoredOccluderOwners.contains(entry.ownerName),
                !dockWindowIDs.contains(entry.id)
            else { continue }
            if screens.contains(where: { Self.coverage(of: entry.bounds, on: $0) >= Self.fullScreenCoverage }) {
                continue
            }
            result.append(TrackedWindow(id: entry.id, ownerName: entry.ownerName, ownerPID: entry.ownerPID, frame: entry.bounds))
        }
        return result
    }

    /// True while a full-screen system panel (Launchpad / Apps, Mission Control, Spotlight)
    /// covers `screen`; the snow there should be hidden.
    func isCoveredByPanel(_ screen: NSScreen) -> Bool {
        guard let id = screen.displayID else { return false }
        return coveredDisplays[id] != nil
    }

    /// Displays at least 90% covered by a full-screen Dock or Spotlight panel above layer 0
    /// (Launchpad / Apps, Mission Control, Spotlight). Hiding all snow is drastic, so a
    /// window must pass every check:
    /// - owned by the Dock or Spotlight, between layer 0 and the overlay;
    /// - not on the Dock's own layers 18…20: there it keeps transparent full-screen
    ///   backdrops that come and go with gestures;
    /// - reasonably opaque (alpha ≥ 0.5);
    /// - not shown together with ⌥: macOS puts up full-screen helper windows for
    ///   modifier gestures (window tiling and the like), which are not panels;
    /// - covering the screen for `coverPolls` polls in a row, so a flash never hides snow.
    private func findCoveredDisplays(in list: [WindowListEntry], optionDown: Bool) -> [CGDirectDisplayID: CoveringWindow] {
        let now = ProcessInfo.processInfo.systemUptime
        if optionDown != optionWasDown {
            optionWasDown = optionDown
            lastOptionChange = now
        }
        let modifierActive = optionDown || now - lastOptionChange < Self.modifierGrace

        let primaryHeight = Coordinates.primaryScreenHeight
        let screens: [(id: CGDirectDisplayID, frame: CGRect)] = NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return (id, Coordinates.cgRect(fromCocoa: screen.frame, primaryHeight: primaryHeight))
        }

        var streaks: [CGWindowID: Int] = [:]
        var modifierWindows: Set<CGWindowID> = []
        var result: [CGDirectDisplayID: CoveringWindow] = [:]
        for entry in list {
            guard entry.layer > 0, entry.layer < Self.overlayLayer, entry.alpha >= Self.minimumCoverAlpha else { continue }
            let isDock = dockLocator.isDockOwned(entry)
            guard isDock || Self.coveringPanelOwners.contains(entry.ownerName) else { continue }
            if isDock && Self.ignoredDockCoverLayers.contains(entry.layer) { continue }
            let displays = screens.filter { Self.coverage(of: entry.bounds, on: $0.frame) >= Self.fullScreenCoverage }
            guard !displays.isEmpty else { continue }

            let known = modifierWindowIDs.contains(entry.id)
            if known || (coverStreaks[entry.id] == nil && modifierActive) {
                if !known {
                    log.info("ignoring full-screen window shown with option: \(entry.id) \(entry.ownerName, privacy: .public) layer \(entry.layer) \(String(describing: entry.bounds), privacy: .public)")
                }
                modifierWindows.insert(entry.id)
                continue
            }
            let streak = (coverStreaks[entry.id] ?? 0) + 1
            streaks[entry.id] = streak
            guard streak >= Self.coverPolls else { continue }
            let window = CoveringWindow(
                id: entry.id,
                ownerName: entry.ownerName,
                layer: entry.layer,
                alpha: entry.alpha,
                bounds: entry.bounds
            )
            for display in displays where result[display.id] == nil {
                result[display.id] = window
            }
        }
        coverStreaks = streaks
        modifierWindowIDs = modifierWindows
        return result
    }

    /// Share of `screen` covered by `rect` (both in the same space), 0...1.
    static func coverage(of rect: CGRect, on screen: CGRect) -> CGFloat {
        let overlap = rect.intersection(screen)
        guard !overlap.isNull, screen.width > 0, screen.height > 0 else { return 0 }
        return (overlap.width * overlap.height) / (screen.width * screen.height)
    }

    // MARK: Window list

    /// Every on-screen window of every layer, front to back, as the window server returns them.
    static func readWindowList() -> [WindowListEntry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log.debug("CGWindowListCopyWindowInfo returned nil")
            return []
        }

        var result: [WindowListEntry] = []
        result.reserveCapacity(list.count)
        for info in list {
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            result.append(WindowListEntry(
                id: number,
                layer: layer,
                ownerPID: pid,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                name: info[kCGWindowName as String] as? String,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: bounds
            ))
        }
        return result
    }

    /// Ordinary app windows (layer 0, visible, not tiny), front to back.
    static func ordinaryWindows(in list: [WindowListEntry]) -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        for entry in list {
            guard entry.layer == 0, entry.alpha > 0 else { continue }
            guard entry.bounds.width > minimumSize.width, entry.bounds.height > minimumSize.height else { continue }
            result.append(TrackedWindow(id: entry.id, ownerName: entry.ownerName, ownerPID: entry.ownerPID, frame: entry.bounds))
        }
        return result
    }

    /// Events turning `old` into `new`: removals first, then additions, moves and resizes
    /// in the front-to-back order of `new`. A window that both moved and resized emits both.
    static func diff(old: [TrackedWindow], new: [TrackedWindow]) -> [WindowEvent] {
        var previous: [CGWindowID: TrackedWindow] = [:]
        for window in old {
            previous[window.id] = window
        }
        let newIDs = Set(new.map(\.id))

        var events: [WindowEvent] = []
        for window in old where !newIDs.contains(window.id) {
            events.append(.removed(window.id))
        }
        for window in new {
            guard let before = previous[window.id] else {
                events.append(.added(window))
                continue
            }
            if before.frame.origin != window.frame.origin {
                events.append(.moved(window, from: before.frame))
            }
            if before.frame.size != window.frame.size {
                events.append(.resized(window, from: before.frame))
            }
        }
        return events
    }

    private static func logEvent(_ event: WindowEvent) {
        switch event {
        case .added(let window):
            log.debug("added \(Int(window.id)) \(window.ownerName, privacy: .public) \(String(describing: window.frame), privacy: .public)")
        case .moved(let window, _):
            log.debug("moved \(Int(window.id)) to \(String(describing: window.frame.origin), privacy: .public)")
        case .resized(let window, _):
            log.debug("resized \(Int(window.id)) to \(String(describing: window.frame.size), privacy: .public)")
        case .removed(let id):
            log.debug("removed \(Int(id))")
        }
    }
}
