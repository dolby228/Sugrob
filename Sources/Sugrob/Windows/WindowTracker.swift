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
        let current = Self.readWindows(excludingPID: ownPID)
        let events = Self.diff(old: windows, new: current)
        let orderChanged = events.isEmpty && current.map(\.id) != windows.map(\.id)

        let docks = currentDockFrames()
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
        if let dock = Self.dockSurface(for: screen) {
            result.append(dock)
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

    /// The Dock area derived from `screen.frame` vs `screen.visibleFrame`:
    /// a bottom inset means a bottom Dock, a left/right inset a side Dock.
    /// The top inset is the menu bar and is ignored.
    /// Note: this is the whole reserved strip, not the exact Dock tile bounds.
    static func dockSurface(for screen: NSScreen) -> TrackedSurface? {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let bottom = visible.minY - frame.minY
        let left = visible.minX - frame.minX
        let right = frame.maxX - visible.maxX

        // Screen-local y-down rects.
        let local: CGRect
        if bottom >= minimumDockInset {
            local = CGRect(x: 0, y: frame.height - bottom, width: frame.width, height: bottom)
        } else if left >= minimumDockInset {
            let top = frame.maxY - visible.maxY
            local = CGRect(x: 0, y: top, width: left, height: visible.height)
        } else if right >= minimumDockInset {
            let top = frame.maxY - visible.maxY
            local = CGRect(x: frame.width - right, y: top, width: right, height: visible.height)
        } else {
            return nil
        }
        return TrackedSurface(id: dockSurfaceID(for: screen), frame: local, kind: .dock)
    }

    private func currentDockFrames() -> [Int: CGRect] {
        var result: [Int: CGRect] = [:]
        for screen in NSScreen.screens {
            if let dock = Self.dockSurface(for: screen) {
                result[dock.id] = dock.frame
            }
        }
        return result
    }

    // MARK: Window list

    /// Front-to-back list of ordinary windows, in the order the window server returns them.
    static func readWindows(excludingPID ownPID: pid_t) -> [TrackedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            log.debug("CGWindowListCopyWindowInfo returned nil")
            return []
        }

        var result: [TrackedWindow] = []
        result.reserveCapacity(list.count)
        for info in list {
            guard
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0,
                let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0 else { continue }
            guard bounds.width > minimumSize.width, bounds.height > minimumSize.height else { continue }

            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            result.append(TrackedWindow(id: number, ownerName: owner, ownerPID: pid, frame: bounds))
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
