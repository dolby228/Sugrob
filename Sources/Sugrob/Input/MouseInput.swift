import AppKit
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "input")

/// Watches the mouse everywhere on screen and drives the snow tools.
///
/// Most of the time the overlay windows ignore mouse events and we only observe with
/// `NSEvent` monitors (global for other apps, local for our own windows). Monitors do not
/// consume events, so the app under the cursor still receives every click and drag.
///
/// Working the snow must not also select text or drag the window underneath, so the
/// overlay of the cursor's screen takes the mouse (dynamic capture) while:
/// - the shovel is over a drift with snow, or carries a load;
/// - ⌥ Option is held over a drift with snow;
/// - a press that started captured has not been released yet.
/// The captured overlay's `SnowView` then feeds its events into the same handler. The
/// mitten only hovers and never captures. Capture is re-checked on every move and
/// modifier change, and by a watchdog timer while it is on.
///
/// - Варежка (mitten): moving the cursor with no button pressed sweeps snow off drifts,
///   kicking it in the direction of movement.
/// - Лопата (shovel): pressing on a drift scoops a bladeful; dragging keeps scooping along
///   the path; letting go after a drag throws the whole load as one clump. After a plain
///   click the load stays on the shovel and the next press dumps it.
/// - ⌥ Option + drag on a drift (any tool): rolls a snowball; letting go throws it.
@MainActor
final class MouseInput {
    typealias WorldProvider = @MainActor () -> [(screen: NSScreen, world: SnowWorld)]

    /// Mitten radius at moderate speed, in points.
    static let mittenRadius: Float = 18
    /// Most snow a single drag sample may shave off, in points of height.
    static let maxScoopDepth: Float = 8
    /// Depth of the bladeful scooped on press.
    static let pressScoopDepth: Float = 10
    /// How close to snow the cursor must be to capture the mouse.
    static let captureTolerance: Float = 12
    static let captureMinHeight: Float = 0.5
    /// How often capture is re-checked while it is on and no events may arrive.
    static let watchdogInterval: TimeInterval = 0.1

    /// Asks the overlay of `screen` to take the mouse; nil gives it back everywhere.
    var onCaptureChange: (@MainActor (_ screen: NSScreen?) -> Void)?
    /// True where the overlay must never take the mouse: the menu bar, system panels,
    /// a hidden snow view. Screen-local y-down point.
    var isCaptureBlocked: (@MainActor (_ screen: NSScreen, _ point: SIMD2<Float>) -> Bool)?

    /// One mouse or modifier event, whichever way it reached us.
    struct PointerEvent {
        enum Kind {
            case moved, down, dragged, up, flags
        }

        let kind: Kind
        /// Cocoa global.
        let location: CGPoint
        let timestamp: TimeInterval
        let option: Bool

        /// Nil for event types the tools do not use.
        init?(_ event: NSEvent) {
            switch event.type {
            case .mouseMoved: kind = .moved
            case .leftMouseDown: kind = .down
            case .leftMouseDragged: kind = .dragged
            case .leftMouseUp: kind = .up
            case .flagsChanged: kind = .flags
            default: return nil
            }
            // Events from global monitors carry no window; the current location is exact enough.
            location = NSEvent.mouseLocation
            timestamp = event.timestamp
            option = event.modifierFlags.contains(.option)
        }

        init(kind: Kind, location: CGPoint, timestamp: TimeInterval, option: Bool) {
            self.kind = kind
            self.location = location
            self.timestamp = timestamp
            self.option = option
        }
    }

    /// The same event can reach us twice (local monitor and the captured view).
    private struct EventKey: Equatable {
        let type: UInt
        let timestamp: TimeInterval
    }

    private struct Target {
        let screen: NSScreen
        let world: SnowWorld
        /// Screen-local, y down.
        let point: SIMD2<Float>
    }

    private enum Drag {
        case idle
        case snowball(world: SnowWorld, screen: NSScreen, id: Int)
        case shovel(dragged: Bool)
        /// This press dumped the load; the rest of it does nothing.
        case shovelDumped
    }

    private let settings: Settings
    private let worlds: WorldProvider
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private var drag: Drag = .idle
    /// Last cursor position, screen-local, and the world it was over.
    private var lastPoint: SIMD2<Float>?
    private weak var lastWorld: SnowWorld?
    private var lastTimestamp: TimeInterval = 0
    private var lastCocoa: CGPoint?
    /// Smoothed cursor velocity in points per second, y down.
    private var velocity = SIMD2<Float>(0, 0)
    /// World whose shovel carries the load / shows the blade.
    private weak var shovelWorld: SnowWorld?
    private var optionDown = false
    private var lastEventKey: EventKey?
    /// Display whose overlay currently takes the mouse.
    private var captureDisplay: CGDirectDisplayID?
    /// The current press went to the captured overlay; capture holds until it is released.
    private var capturedPress = false
    private var watchdog: Timer?

    init(settings: Settings, worlds: @escaping WorldProvider) {
        self.settings = settings
        self.worlds = worlds
    }

    func start() {
        guard globalMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.receive(event)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            MainActor.assumeIsolated {
                self.receive(event)
            }
            return event
        }
        log.info("mouse monitors \(self.globalMonitor == nil ? "unavailable" : "started", privacy: .public)")
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        cancel()
        log.info("mouse monitors stopped")
    }

    /// Drops whatever is in progress: a held snowball falls, the shovel load is dumped.
    func cancel() {
        if case .snowball(let world, _, let id) = drag {
            world.releaseBall(id, velocity: .zero)
        }
        drag = .idle
        capturedPress = false
        dumpCarriedLoad()
        setCapture(nil)
    }

    /// Switching away from the shovel drops what it carries.
    func toolChanged() {
        if settings.tool != .shovel {
            dumpCarriedLoad()
        }
        updateCapture(at: locate(NSEvent.mouseLocation))
    }

    // MARK: Events

    /// Entry point for every source of mouse events.
    func receive(_ event: NSEvent) {
        guard let pointer = PointerEvent(event) else { return }
        let key = EventKey(type: UInt(event.type.rawValue), timestamp: event.timestamp)
        guard key != lastEventKey else { return }
        lastEventKey = key
        handle(pointer)
    }

    private func handle(_ event: PointerEvent) {
        optionDown = event.option
        if event.kind == .flags {
            if !isGestureInProgress {
                updateCapture(at: locate(event.location))
            }
            return
        }
        guard !settings.isPaused else {
            if case .idle = drag {} else { cancel() }
            capturedPress = false
            setCapture(nil)
            return
        }

        if event.kind == .down {
            capturedPress = captureDisplay != nil
        }
        let located = locate(event.location)
        process(event, located: located)
        if event.kind == .up {
            capturedPress = false
        }
        updateCapture(at: located)
    }

    private func process(_ event: PointerEvent, located: Target?) {
        let type = event.kind
        let cocoa = event.location
        trackVelocity(cocoa, timestamp: event.timestamp, reset: type == .down)
        defer { lastCocoa = cocoa }
        defer {
            lastPoint = located?.point
            lastWorld = located?.world
        }

        // A snowball stays in its own world even when the cursor leaves that screen.
        if case .snowball(let world, let screen, let id) = drag,
           type == .dragged || type == .up {
            let point = Self.localPoint(cocoa, on: screen)
            let alive = world.rollBall(id, to: point)
            if type == .up {
                world.releaseBall(id, velocity: velocity)
                log.debug("snowball \(id) released")
                drag = .idle
            } else if !alive {
                drag = .idle
            }
            return
        }

        guard let target = located else {
            if type == .up {
                if case .shovel(true) = drag { dumpCarriedLoad() }
                drag = .idle
            }
            return
        }

        switch type {
        case .moved:
            mouseMoved(target)
        case .down:
            mouseDown(target, option: event.option)
        case .dragged:
            mouseDragged(target)
        case .up:
            mouseUp(target)
        case .flags:
            break
        }
    }

    private func mouseMoved(_ target: Target) {
        switch settings.tool {
        case .mitten:
            sweepAlongPath(to: target)
        case .shovel:
            carryShovel(to: target)
        }
    }

    private func mouseDown(_ target: Target, option: Bool) {
        drag = .idle
        if option {
            if let id = target.world.beginRoll(at: target.point) {
                drag = .snowball(world: target.world, screen: target.screen, id: id)
                log.debug("snowball \(id) started")
            }
            return
        }
        guard settings.tool == .shovel else { return }

        if let carrier = shovelWorld, carrier.shovelLoad > 0 {
            carryShovel(to: target)
            dump(in: target.world, at: target.point)
            drag = .shovelDumped
            return
        }
        // Only a press on snow picks up the shovel, so ordinary clicks stay ordinary.
        guard target.world.driftSurfaceID(at: target.point, tolerance: 12, minHeight: 0.05) != nil else { return }
        let taken = target.world.scoop(at: target.point, depth: Self.pressScoopDepth)
        showShovel(in: target.world, at: target.point)
        drag = .shovel(dragged: false)
        log.debug("shovel scooped \(Double(taken), privacy: .public) pt²")
    }

    private func mouseDragged(_ target: Target) {
        switch drag {
        case .shovel:
            drag = .shovel(dragged: true)
            carryShovel(to: target)
            scoopAlongPath(to: target)
        case .idle, .shovelDumped, .snowball:
            break
        }
    }

    private func mouseUp(_ target: Target) {
        switch drag {
        case .shovel(let dragged):
            carryShovel(to: target)
            if dragged {
                dump(in: target.world, at: target.point)
            } else if target.world.shovelLoad <= 0 {
                hideShovel()
            }
        case .shovelDumped, .idle, .snowball:
            break
        }
        drag = .idle
    }

    // MARK: Capture

    private var isGestureInProgress: Bool {
        if capturedPress { return true }
        if case .idle = drag { return false }
        return true
    }

    /// Takes or gives back the mouse for the cursor at `target`.
    private func updateCapture(at target: Target?) {
        if isGestureInProgress {
            // Never switch mid-gesture: a captured press keeps its window, and a press
            // that went to another app is not grabbed halfway through.
            if captureDisplay != nil { NSCursor.closedHand.set() }
            return
        }
        // A button held down for another app (dragging a window over a drift).
        if NSEvent.pressedMouseButtons & 1 != 0 {
            setCapture(nil)
            return
        }
        guard let target, wantsCapture(target) else {
            setCapture(nil)
            return
        }
        setCapture(target.screen)
    }

    private func wantsCapture(_ target: Target) -> Bool {
        guard !settings.isPaused else { return false }
        if isCaptureBlocked?(target.screen, target.point) ?? false { return false }
        if settings.tool == .shovel, let carrier = shovelWorld, carrier.shovelLoad > 0 { return true }
        guard settings.tool == .shovel || optionDown else { return false }
        return target.world.driftSurfaceID(
            at: target.point,
            tolerance: Self.captureTolerance,
            minHeight: Self.captureMinHeight
        ) != nil
    }

    private func setCapture(_ screen: NSScreen?) {
        let display = screen?.displayID
        guard display != captureDisplay else {
            if display != nil { NSCursor.openHand.set() }
            return
        }
        captureDisplay = display
        onCaptureChange?(display == nil ? nil : screen)
        if let display {
            NSCursor.openHand.set()
            startWatchdog()
            log.debug("mouse captured on display \(Int(display))")
        } else {
            NSCursor.arrow.set()
            stopWatchdog()
            log.debug("mouse capture released")
        }
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkCapture()
            }
        }
        timer.tolerance = Self.watchdogInterval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    /// While captured, moves over our own window may not be reported, snow can melt under a
    /// still cursor and a release can get lost; none of that may leave the mouse captured.
    private func checkCapture() {
        guard captureDisplay != nil else {
            stopWatchdog()
            return
        }
        let location = NSEvent.mouseLocation
        let option = NSEvent.modifierFlags.contains(.option)
        if isGestureInProgress {
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            log.debug("mouse up never arrived, finishing the gesture")
            handle(PointerEvent(kind: .up, location: location, timestamp: ProcessInfo.processInfo.systemUptime, option: option))
            return
        }
        optionDown = option
        updateCapture(at: locate(location))
    }

    // MARK: Tools

    private func sweepAlongPath(to target: Target) {
        let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
        let radius = Self.mittenRadius * max(0.8, min(1.6, 0.8 + speed / 1200))
        for point in pathSamples(to: target, spacing: radius * 0.6) {
            target.world.sweep(at: point, radius: radius, direction: velocity)
        }
    }

    private func scoopAlongPath(to target: Target) {
        guard let from = lastPoint, lastWorld === target.world else {
            target.world.scoop(at: target.point, depth: 1)
            return
        }
        let samples = pathSamples(to: target, spacing: SnowWorld.shovelHalfWidth * 0.5)
        guard !samples.isEmpty else { return }
        let d = target.point - from
        let distance = (d.x * d.x + d.y * d.y).squareRoot()
        let depth = max(0.5, min(Self.maxScoopDepth, distance * 0.35 / Float(samples.count)))
        for point in samples {
            target.world.scoop(at: point, depth: depth)
        }
    }

    /// Points from the previous cursor position to the current one, `spacing` apart,
    /// ending at the current one. Just the current point after a jump between screens.
    private func pathSamples(to target: Target, spacing: Float) -> [SIMD2<Float>] {
        guard let from = lastPoint, lastWorld === target.world else { return [target.point] }
        let d = target.point - from
        let distance = (d.x * d.x + d.y * d.y).squareRoot()
        guard distance > 0.01 else { return [] }
        let count = min(40, max(1, Int((distance / max(1, spacing)).rounded(.up))))
        var samples: [SIMD2<Float>] = []
        samples.reserveCapacity(count)
        for i in 1...count {
            let t = Float(i) / Float(count)
            samples.append(from + d * t)
        }
        return samples
    }

    /// Keeps the blade (and its load) under the cursor, on whichever screen it is.
    private func carryShovel(to target: Target) {
        if let carrier = shovelWorld, carrier !== target.world {
            carrier.transferShovelLoad(to: target.world)
        }
        let dragging: Bool
        if case .shovel = drag { dragging = true } else { dragging = false }
        if target.world.shovelLoad > 0 || dragging {
            showShovel(in: target.world, at: target.point)
        } else {
            hideShovel()
        }
    }

    private func showShovel(in world: SnowWorld, at point: SIMD2<Float>) {
        if let carrier = shovelWorld, carrier !== world {
            carrier.shovelPosition = nil
        }
        world.shovelPosition = point
        shovelWorld = world
    }

    private func hideShovel() {
        shovelWorld?.shovelPosition = nil
        shovelWorld = nil
    }

    private func dump(in world: SnowWorld, at point: SIMD2<Float>) {
        let load = world.shovelLoad
        if world.dump(at: point, velocity: velocity) != nil {
            log.debug("shovel dumped \(Double(load), privacy: .public) pt²")
        }
        hideShovel()
    }

    private func dumpCarriedLoad() {
        guard let carrier = shovelWorld else { return }
        if carrier.shovelLoad > 0, let point = carrier.shovelPosition {
            carrier.dump(at: point, velocity: .zero)
        }
        hideShovel()
    }

    // MARK: Geometry

    private func trackVelocity(_ cocoa: CGPoint, timestamp: TimeInterval, reset: Bool) {
        defer { lastTimestamp = timestamp }
        guard !reset, let last = lastCocoa else {
            velocity = .zero
            return
        }
        let dt = timestamp - lastTimestamp
        guard dt > 0.0005, dt < 0.2 else {
            if dt >= 0.2 { velocity = .zero }
            return
        }
        // Cocoa y grows up; snow space grows down.
        let instant = SIMD2<Float>(Float((cocoa.x - last.x) / dt), Float((last.y - cocoa.y) / dt))
        velocity += (instant - velocity) * 0.5
    }

    private func locate(_ cocoa: CGPoint) -> Target? {
        let available = worlds()
        guard let entry = available.first(where: { NSMouseInRect(cocoa, $0.screen.frame, false) }) else {
            return nil
        }
        return Target(screen: entry.screen, world: entry.world, point: Self.localPoint(cocoa, on: entry.screen))
    }

    private static func localPoint(_ cocoa: CGPoint, on screen: NSScreen) -> SIMD2<Float> {
        let local = Coordinates.screenLocal(fromCocoa: cocoa, screenFrame: screen.frame)
        return SIMD2(Float(local.x), Float(local.y))
    }
}
