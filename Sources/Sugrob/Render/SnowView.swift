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
        renderer.menuBarInset = Float(max(0, screen.frame.maxY - screen.visibleFrame.maxY))
        configureLayer()
        syncWorldBounds(screen.frame.size)
        if surfaces != lastSurfaces {
            lastSurfaces = surfaces
            // Occluders never carry snow; the renderer only uses them to hide drifts.
            world.setSurfaces(surfaces.filter { $0.kind != .occluder }.map(Self.surface(from:)))
        }
        debugView?.update(surfaces: surfaces, screen: screen)
    }

    /// Pause freezes the world, stops the draw loop and hides the view.
    func setPaused(_ paused: Bool) {
        isSnowPaused = paused
        world.isPaused = paused
        isHidden = paused
        isPaused = paused
        // Do not count the paused time as one long frame.
        lastFrameTime = nil
        log.debug("snow view \(paused ? "paused" : "resumed", privacy: .public)")
    }

    static func surface(from tracked: TrackedSurface) -> Surface {
        Surface(id: tracked.id, rect: Rect(
            x: Float(tracked.frame.minX),
            y: Float(tracked.frame.minY),
            width: Float(tracked.frame.width),
            height: Float(tracked.frame.height)
        ))
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
        guard !isSnowPaused else { return }
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
