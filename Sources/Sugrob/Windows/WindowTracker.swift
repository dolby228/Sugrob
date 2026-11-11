import AppKit
import os

private let log = Logger(subsystem: "dev.sugrob", category: "tracker")

/// Polls the window server for on-screen windows of other apps and reports what changed.
///
/// Uses `CGWindowListCopyWindowInfo`, which needs no permissions for window bounds.
/// Only ordinary app windows are kept: layer 0, visible (alpha > 0), larger than 40x40
/// and not owned by this process (our own overlay windows must never collect snow).
@MainActor
final class WindowTracker: NSObject {
    /// Called on the main thread after a poll that changed anything: the window list
    /// (including z-order) or the Dock area. `windows` is ordered front to back.
    var onUpdate: (@MainActor (_ windows: [TrackedWindow], _ events: [WindowEvent]) -> Void)?

    /// Current windows, front to back, in CG global coordinates.
    private(set) var windows: [TrackedWindow] = []

    let interval: TimeInterval
    static let minimumSize = CGSize(width: 40, height: 40)
    /// Insets smaller than this (e.g. the sliver left by an auto-hidden Dock) are ignored.
    static let minimumDockInset: CGFloat = 8

    private var timer: Timer?
    private var dockFrames: [Int: CGRect] = [:]
    private let dockLocator = DockLocator()
    private let ownPID = getpid()

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
        let list = Self.readWindowList()
        let current = Self.ordinaryWindows(in: list, excludingPID: ownPID)
        let events = Self.diff(old: windows, new: current)
        let orderChanged = events.isEmpty && current.map(\.id) != windows.map(\.id)

        let docks = dockLocator.locate(in: list, windows: current).frames
        let docksChanged = docks != dockFrames

        guard !events.isEmpty || orderChanged || docksChanged else { return }

        windows = current
        dockFrames = docks
        for event in events {
            Self.logEvent(event)
        }
        if docksChanged {
            log.debug("dock areas changed: \(String(describing: docks), privacy: .public)")
        }
        onUpdate?(current, events)
    }

    // MARK: Surfaces

    /// Surfaces visible on `screen`, front to back, in that screen's local y-down space.
    /// The Dock comes first because it is drawn above all normal windows.
    /// Window frames are not clipped to the screen; the consumer clips if needed.
    func surfaces(for screen: NSScreen) -> [TrackedSurface] {
        let primaryHeight = Coordinates.primaryScreenHeight
        let screenFrame = screen.frame
        let screenCG = Coordinates.cgRect(fromCocoa: screenFrame, primaryHeight: primaryHeight)

        var result: [TrackedSurface] = []
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

    /// Synthetic negative id of the Dock surface on a screen; stable across polls.
    static func dockSurfaceID(for screen: NSScreen) -> Int {
        -(Int(screen.displayID ?? 0) + 1)
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

    /// Ordinary app windows (layer 0, visible, not tiny, not ours), front to back.
    static func ordinaryWindows(in list: [WindowListEntry], excludingPID ownPID: pid_t) -> [TrackedWindow] {
        var result: [TrackedWindow] = []
        for entry in list {
            guard entry.layer == 0, entry.ownerPID != ownPID, entry.alpha > 0 else { continue }
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
