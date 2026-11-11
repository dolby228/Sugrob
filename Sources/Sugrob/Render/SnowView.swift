import AppKit
import MetalKit
import QuartzCore
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "render")

/// Transparent Metal view filling one overlay window. Owns the `SnowWorld` of its screen
/// (bounds are screen-local, y down) and steps it from MTKView's own draw loop.
@MainActor
final class SnowView: MTKView, OverlayContent {
    let world: SnowWorld

    private let renderer: SnowRenderer
    private var binder: WorldSettingsBinder?
    private var lastFrameTime: CFTimeInterval?
    private var lastSurfaces: [TrackedSurface] = []
    private var lastScreen: NSScreen?
    private var debugView: DebugOverlayView?
    private var framesPerSecond = 60
    private var isSnowPaused = false
    /// A full-screen system panel covers the screen; drawing stops, the world keeps its state.
    private var isCovered = false

    /// Mouse events reaching this view while its overlay takes the mouse.
    var onMouseEvent: (@MainActor (NSEvent) -> Void)?
    private var trackingArea: NSTrackingArea?

    /// Longest simulated step; a stalled frame must not teleport flakes through drifts.
    static let maxStep: CFTimeInterval = 1.0 / 20.0

    init(frame frameRect: NSRect, pipelines: RenderPipelines, settings: Settings) {
        world = SnowWorld(bounds: Rect(
            x: 0,
            y: 0,
            width: Float(frameRect.width),
            height: Float(frameRect.height)
        ))
        renderer = SnowRenderer(pipelines: pipelines)
        super.init(frame: frameRect, device: pipelines.device)

        colorPixelFormat = RenderPipelines.colorPixelFormat
        depthStencilPixelFormat = .invalid
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        autoResizeDrawable = true
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = framesPerSecond
        isPaused = false
        configureLayer()

        binder = WorldSettingsBinder(settings: settings, view: self)
    }

    required init(coder: NSCoder) {
        fatalError("SnowView is created in code only")
    }

    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureLayer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        configureLayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncWorldBounds(newSize)
    }

    /// The window server composites the layer only if it is marked non-opaque and every
    /// pixel we do not draw stays at alpha 0.
    private func configureLayer() {
        wantsLayer = true
        guard let layer else { return }
        layer.isOpaque = false
        layer.backgroundColor = CGColor.clear
        let scale = lastScreen?.backingScaleFactor ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if layer.contentsScale != scale {
            layer.contentsScale = scale
        }
    }

    private func syncWorldBounds(_ size: NSSize) {
        let rect = Rect(x: 0, y: 0, width: Float(size.width), height: Float(size.height))
        if world.bounds != rect {
            world.bounds = rect
        }
    }

    // MARK: OverlayContent

    func update(surfaces: [TrackedSurface], screen: NSScreen) {
        lastScreen = screen
        // Only the top inset: the Dock's side and bottom insets must not clip anything.
        // In a full-screen Space the bar is hidden but the clip is kept: the app starts
        // below it anyway (or below the notch), so nothing worth drawing is lost.
        renderer.menuBarInset = Float(max(0, screen.frame.maxY - screen.visibleFrame.maxY))
        configureLayer()
        syncWorldBounds(screen.frame.size)
        if surfaces != lastSurfaces {
            lastSurfaces = surfaces
            // Occluders never carry snow; the renderer only uses them to hide drifts.
            world.setSurfaces(surfaces.filter { $0.kind != .occluder }.map(Self.surface(from:)))
            renderer.occluders = surfaces.filter { $0.kind == .occluder }.map { Self.surface(from: $0).rect }
        }
        debugView?.update(surfaces: surfaces, screen: screen)
    }

    /// Pause freezes the world, stops the draw loop and hides the view.
    func setPaused(_ paused: Bool) {
        isSnowPaused = paused
        world.isPaused = paused
        applyVisibility()
        log.debug("snow view \(paused ? "paused" : "resumed", privacy: .public)")
    }

    /// Hides the snow while a full-screen system panel covers the screen. The world is not
    /// paused, it simply is not stepped until the panel goes away.
    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        applyVisibility()
        log.debug("snow view \(covered ? "covered by a system panel" : "uncovered", privacy: .public)")
    }

    private func applyVisibility() {
        let hidden = isSnowPaused || isCovered
        isHidden = hidden
        isPaused = hidden
        // Do not count the hidden time as one long frame.
        lastFrameTime = nil
    }

    static func surface(from tracked: TrackedSurface) -> Surface {
        Surface(id: tracked.id, rect: Rect(
            x: Float(tracked.frame.minX),
            y: Float(tracked.frame.minY),
            width: Float(tracked.frame.width),
            height: Float(tracked.frame.height)
        ))
    }

    // MARK: Mouse capture

    /// The overlay is never key; the first click must do its work right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseDragged(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseUp(with event: NSEvent) { onMouseEvent?(event) }
    override func mouseMoved(with event: NSEvent) { onMouseEvent?(event) }

    /// Moves over a captured overlay reach the view even though its window is never key.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingArea == nil else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// True where the overlay must not take the mouse: the snow is hidden, the point is in
    /// the menu bar, or a system panel lies above the drifts there. Screen-local y-down.
    func blocksCapture(at point: CGPoint) -> Bool {
        if isHidden { return true }
        if point.y < CGFloat(renderer.menuBarInset) { return true }
        return lastSurfaces.contains { $0.kind == .occluder && $0.frame.contains(point) }
    }

    // MARK: Power

    func applyPower(_ profile: PowerMonitor.Profile) {
        world.particleBudgetScale = profile.budgetScale
        framesPerSecond = profile.framesPerSecond
        if preferredFramesPerSecond != profile.framesPerSecond {
            preferredFramesPerSecond = profile.framesPerSecond
        }
    }

    // MARK: Debug outlines

    /// Keeps a `DebugOverlayView` on top of the snow while enabled.
    var showsDebugOutlines = false {
        didSet {
            guard showsDebugOutlines != oldValue else { return }
            if showsDebugOutlines {
                let outlines = DebugOverlayView(frame: bounds)
                outlines.autoresizingMask = [.width, .height]
                outlines.showsOutlines = true
                addSubview(outlines)
                if let lastScreen {
                    outlines.update(surfaces: lastSurfaces, screen: lastScreen)
                }
                debugView = outlines
            } else {
                debugView?.removeFromSuperview()
                debugView = nil
            }
        }
    }

    // MARK: Drawing

    /// Called by MTKView's display loop at `preferredFramesPerSecond`.
    override func draw(_ dirtyRect: NSRect) {
        guard !isSnowPaused, !isCovered else { return }
        let now = CACurrentMediaTime()
        let dt: CFTimeInterval
        if let last = lastFrameTime {
            dt = min(max(now - last, 0), Self.maxStep)
        } else {
            dt = 1.0 / Double(max(1, framesPerSecond))
        }
        lastFrameTime = now
        world.step(dt: Float(dt))
        renderer.render(world: world, in: self)
    }
}
