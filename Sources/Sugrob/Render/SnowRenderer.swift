import Foundation
import Metal
import MetalKit
import SnowCore
import os

private let log = Logger(subsystem: "dev.sugrob", category: "render")

// Layouts must match the structs in `ShaderSource`.

struct FlakeInstance {
    var position: SIMD2<Float>
    var size: Float
    var opacity: Float
    var rotation: Float
    var lumpiness: Float
}

struct DriftVertex {
    var position: SIMD2<Float>
    var dist: Float
    var t: Float
}

/// One instanced shape of the snowball/snowman/shovel pass. 48 bytes, like the shader struct.
struct ShapeInstance {
    enum Kind: Float {
        case ball = 0
        case disc = 1
        case triangle = 2
        case bar = 3
        case blob = 4
    }

    var center: SIMD2<Float>
    /// Half extents in points.
    var size: SIMD2<Float>
    /// Straight (not premultiplied) RGBA.
    var color: SIMD4<Float>
    var rotation: Float
    var kind: Float
    var seed: Float
    var pad: Float

    init(kind: Kind, center: SIMD2<Float>, size: SIMD2<Float>, color: SIMD4<Float> = SIMD4(1, 1, 1, 1), rotation: Float = 0, seed: Float = 0) {
        self.center = center
        self.size = size
        self.color = color
        self.rotation = rotation
        self.kind = kind.rawValue
        self.seed = seed
        self.pad = 0
    }
}

struct RenderUniforms {
    var viewportSize: SIMD2<Float>
}

enum RenderSetupError: Error, CustomStringConvertible {
    case missingFunction(String)
    case depthStencilState
    case commandQueue

    var description: String {
        switch self {
        case .missingFunction(let name): return "shader function \(name) not found"
        case .depthStencilState: return "could not create depth/stencil state"
        case .commandQueue: return "could not create command queue"
        }
    }
}

/// Device, queue and compiled pipelines. Built once and shared by every `SnowView`.
final class RenderPipelines {
    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    static let stencilPixelFormat: MTLPixelFormat = .stencil8

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let flakePipeline: MTLRenderPipelineState
    let driftPipeline: MTLRenderPipelineState
    let occluderPipeline: MTLRenderPipelineState
    let shapePipeline: MTLRenderPipelineState
    /// Occluders keep the smallest surface index covering each pixel.
    let occluderStencil: MTLDepthStencilState
    /// A drift is drawn only where no surface in front of it was stamped.
    let driftStencil: MTLDepthStencilState
    let flakeStencil: MTLDepthStencilState
    /// Apple GPUs can keep the stencil buffer in tile memory only.
    let supportsMemorylessStencil: Bool

    /// Nil (with an error logged) when there is no Metal device or setup fails.
    static func makeDefault() -> RenderPipelines? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log.error("MTLCreateSystemDefaultDevice returned nil; falling back to debug overlay")
            return nil
        }
        do {
            let pipelines = try RenderPipelines(device: device)
            log.info("metal renderer ready on \(device.name, privacy: .public)")
            return pipelines
        } catch {
            log.error("metal setup failed: \(String(describing: error), privacy: .public); falling back to debug overlay")
            return nil
        }
    }

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw RenderSetupError.commandQueue }
        queue.label = "Sugrob"
        commandQueue = queue

        let library = try device.makeLibrary(source: ShaderSource.source, options: nil)
        func function(_ name: String) throws -> MTLFunction {
            guard let fn = library.makeFunction(name: name) else {
                throw RenderSetupError.missingFunction(name)
            }
            return fn
        }

        flakePipeline = try Self.makePipeline(
            device: device,
            label: "flakes",
            vertex: try function(ShaderSource.flakeVertex),
            fragment: try function(ShaderSource.flakeFragment),
            writesColor: true
        )
        driftPipeline = try Self.makePipeline(
            device: device,
            label: "drifts",
            vertex: try function(ShaderSource.driftVertex),
            fragment: try function(ShaderSource.driftFragment),
            writesColor: true
        )
        occluderPipeline = try Self.makePipeline(
            device: device,
            label: "occluders",
            vertex: try function(ShaderSource.driftVertex),
            fragment: try function(ShaderSource.occluderFragment),
            writesColor: false
        )
        shapePipeline = try Self.makePipeline(
            device: device,
            label: "shapes",
            vertex: try function(ShaderSource.shapeVertex),
            fragment: try function(ShaderSource.shapeFragment),
            writesColor: true
        )

        guard
            let occluder = Self.makeStencilState(device: device, compare: .less, pass: .replace, writeMask: 0xFF),
            let drift = Self.makeStencilState(device: device, compare: .lessEqual, pass: .keep, writeMask: 0),
            let flake = Self.makeStencilState(device: device, compare: .always, pass: .keep, writeMask: 0)
        else { throw RenderSetupError.depthStencilState }
        occluderStencil = occluder
        driftStencil = drift
        flakeStencil = flake

        supportsMemorylessStencil = device.supportsFamily(.apple1)
    }

    private static func makePipeline(
        device: MTLDevice,
        label: String,
        vertex: MTLFunction,
        fragment: MTLFunction,
        writesColor: Bool
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.stencilAttachmentPixelFormat = stencilPixelFormat

        let color: MTLRenderPipelineColorAttachmentDescriptor = descriptor.colorAttachments[0]
        color.pixelFormat = colorPixelFormat
        if writesColor {
            // Premultiplied alpha: the window server composites the layer as premultiplied.
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add
            color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .one
            color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            color.writeMask = []
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func makeStencilState(
        device: MTLDevice,
        compare: MTLCompareFunction,
        pass: MTLStencilOperation,
        writeMask: UInt32
    ) -> MTLDepthStencilState? {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = compare
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = pass
        stencil.readMask = 0xFF
        stencil.writeMask = writeMask

        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = false
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return device.makeDepthStencilState(descriptor: descriptor)
    }
}

/// Turns one `SnowWorld` into draw calls for one `MTKView`.
///
/// Per frame: flakes become instances of a soft sprite; each drift becomes a triangle
/// list (body + thin feather strip above the top edge for anti-aliasing). Drifts of
/// windows further back are hidden where a window in front covers them, using the
/// stencil buffer: every surface stamps its rect with `index + 1` (keeping the minimum),
/// and a drift with reference `index + 1` only passes where the stamp is not smaller.
///
/// Snowballs, snowmen, dumped clumps and the shovel are instanced shapes drawn after the
/// drifts. Those standing on a surface use that surface's stencil reference, so a window
/// in front hides them like it hides the drift; flying ones are drawn over everything.
///
/// Buffers are triple-buffered behind a semaphore and grow on demand, so steady-state
/// frames allocate nothing.
@MainActor
final class SnowRenderer {
    static let maxFramesInFlight = 3
    /// Stencil is 8 bit and 255 is the clear value, so this many surfaces can be ordered.
    static let maxOrderedSurfaces = 254
    /// Height of the anti-aliasing strip above the top edge, in points.
    static let feather: Float = 1.5
    /// Curve points per column gap when the bank outline is subdivided.
    static let driftSubdivisions = 3
    /// Standard deviation (pt) of the gaussian that softens the simulated heights.
    static let driftSmoothing: Float = 7

    private struct DrawRange {
        var start: Int
        var count: Int
        var reference: UInt32
    }

    private let pipelines: RenderPipelines
    private let inFlight = DispatchSemaphore(value: SnowRenderer.maxFramesInFlight)
    private var frameIndex = 0
    private var flakeBuffers: [MTLBuffer?] = Array(repeating: nil, count: SnowRenderer.maxFramesInFlight)
    private var driftBuffers: [MTLBuffer?] = Array(repeating: nil, count: SnowRenderer.maxFramesInFlight)
    private var shapeBuffers: [MTLBuffer?] = Array(repeating: nil, count: SnowRenderer.maxFramesInFlight)
    private var stencilTexture: MTLTexture?

    private var displayHeights: [Float] = []
    private var smoothingKernel: [Float] = []
    /// Subdivided bank outline: local x, height and slope (dh/dx) per point.
    private var driftCurve: [SIMD3<Float>] = []
    private var occluderDraws: [DrawRange] = []
    private var driftDraws: [DrawRange] = []
    private var shapeDraws: [DrawRange] = []

    private struct PendingShape {
        var reference: UInt32
        var sequence: Int
        var instance: ShapeInstance
    }

    private var pendingShapes: [PendingShape] = []
    /// Back-most surface index that has a shape standing on it, or -1.
    private var backmostShapeSurface = -1

    init(pipelines: RenderPipelines) {
        self.pipelines = pipelines
    }

    func render(world: SnowWorld, in view: MTKView) {
        let viewport = SIMD2<Float>(Float(view.bounds.width), Float(view.bounds.height))
        guard viewport.x > 0, viewport.y > 0 else { return }

        inFlight.wait()
        var committed = false
        defer {
            if !committed { inFlight.signal() }
        }

        frameIndex = (frameIndex + 1) % Self.maxFramesInFlight
        let flakeCount = fillFlakes(world.flakes)
        let shapeBuffer = fillShapes(world)
        let driftBuffer = fillDrifts(world)

        guard
            let pass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let target = pass.colorAttachments[0].texture,
            let stencil = ensureStencil(width: target.width, height: target.height),
            let commandBuffer = pipelines.commandQueue.makeCommandBuffer()
        else { return }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.stencilAttachment.texture = stencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        pass.stencilAttachment.clearStencil = 255

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "snow"
        var uniforms = RenderUniforms(viewportSize: viewport)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 1)

        if let driftBuffer {
            encoder.setVertexBuffer(driftBuffer, offset: 0, index: 0)

            encoder.setRenderPipelineState(pipelines.occluderPipeline)
            encoder.setDepthStencilState(pipelines.occluderStencil)
            for draw in occluderDraws {
                encoder.setStencilReferenceValue(draw.reference)
                encoder.drawPrimitives(type: .triangle, vertexStart: draw.start, vertexCount: draw.count)
            }

            encoder.setRenderPipelineState(pipelines.driftPipeline)
            encoder.setDepthStencilState(pipelines.driftStencil)
            for draw in driftDraws {
                encoder.setStencilReferenceValue(draw.reference)
                encoder.drawPrimitives(type: .triangle, vertexStart: draw.start, vertexCount: draw.count)
            }
        }

        if let shapeBuffer, !shapeDraws.isEmpty {
            encoder.setRenderPipelineState(pipelines.shapePipeline)
            encoder.setDepthStencilState(pipelines.driftStencil)
            encoder.setVertexBuffer(shapeBuffer, offset: 0, index: 0)
            let stride = MemoryLayout<ShapeInstance>.stride
            for draw in shapeDraws {
                encoder.setVertexBufferOffset(draw.start * stride, index: 0)
                encoder.setStencilReferenceValue(draw.reference)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: draw.count)
            }
        }

        if flakeCount > 0, let flakeBuffer = flakeBuffers[frameIndex] {
            encoder.setRenderPipelineState(pipelines.flakePipeline)
            encoder.setDepthStencilState(pipelines.flakeStencil)
            encoder.setStencilReferenceValue(0)
            encoder.setVertexBuffer(flakeBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: flakeCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        Self.signalOnCompletion(commandBuffer, semaphore: inFlight)
        commandBuffer.commit()
        committed = true
    }

    /// Kept nonisolated so the completion closure never inherits main-actor isolation.
    private nonisolated static func signalOnCompletion(_ commandBuffer: MTLCommandBuffer, semaphore: DispatchSemaphore) {
        commandBuffer.addCompletedHandler { _ in
            semaphore.signal()
        }
    }

    // MARK: Buffers

    private func ensureBuffer(in slots: inout [MTLBuffer?], bytes: Int, label: String) -> MTLBuffer? {
        if let existing = slots[frameIndex], existing.length >= bytes {
            return existing
        }
        var capacity = 16 * 1024
        while capacity < bytes { capacity *= 2 }
        guard let created = pipelines.device.makeBuffer(length: capacity, options: .storageModeShared) else {
            log.error("could not allocate \(capacity) byte \(label, privacy: .public) buffer")
            slots[frameIndex] = nil
            return nil
        }
        created.label = label
        slots[frameIndex] = created
        let slot = frameIndex
        log.debug("\(label, privacy: .public) buffer \(slot) grew to \(capacity) bytes")
        return created
    }

    private func ensureStencil(width: Int, height: Int) -> MTLTexture? {
        if let texture = stencilTexture, texture.width == width, texture.height == height {
            return texture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderPipelines.stencilPixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = pipelines.supportsMemorylessStencil ? .memoryless : .private
        let texture = pipelines.device.makeTexture(descriptor: descriptor)
        texture?.label = "stencil"
        stencilTexture = texture
        if texture == nil {
            log.error("could not create \(width)x\(height) stencil texture")
        }
        return texture
    }

    // MARK: Flakes

    private func fillFlakes(_ flakes: [Flake]) -> Int {
        let count = flakes.count
        guard count > 0 else { return 0 }
        let instanceStride = MemoryLayout<FlakeInstance>.stride
        guard let buffer = ensureBuffer(in: &flakeBuffers, bytes: count * instanceStride, label: "flakes") else { return 0 }
        let out = buffer.contents().bindMemory(to: FlakeInstance.self, capacity: count)
        flakes.withUnsafeBufferPointer { src in
            for i in 0..<count {
                let f = src[i]
                out[i] = FlakeInstance(
                    position: f.position,
                    size: f.size,
                    opacity: f.opacity,
                    rotation: f.rotation,
                    lumpiness: f.isDebris ? 1 : 0
                )
            }
        }
        return count
    }

    // MARK: Shapes

    private static let coal = SIMD4<Float>(0.10, 0.10, 0.12, 1)
    private static let carrot = SIMD4<Float>(0.98, 0.50, 0.10, 1)
    private static let scarf = SIMD4<Float>(0.86, 0.13, 0.16, 1)
    private static let scarfShade = SIMD4<Float>(0.72, 0.09, 0.12, 1)
    private static let blade = SIMD4<Float>(0.56, 0.61, 0.69, 0.95)
    private static let handle = SIMD4<Float>(0.55, 0.37, 0.21, 0.95)

    /// Stencil reference of the surface an object stands on; 0 (always visible) if none.
    private func reference(for surfaceID: Int?, in world: SnowWorld) -> UInt32 {
        guard let surfaceID, let k = world.surfaceOrder.firstIndex(of: surfaceID) else { return 0 }
        guard k < Self.maxOrderedSurfaces else { return 255 }
        backmostShapeSurface = max(backmostShapeSurface, k)
        return UInt32(k + 1)
    }

    private func addShape(_ instance: ShapeInstance, reference: UInt32) {
        pendingShapes.append(PendingShape(reference: reference, sequence: pendingShapes.count, instance: instance))
    }

    /// Builds the shape instances, grouped by stencil reference (back surfaces first,
    /// flying objects last). Returns the buffer or nil when there is nothing to draw.
    private func fillShapes(_ world: SnowWorld) -> MTLBuffer? {
        pendingShapes.removeAll(keepingCapacity: true)
        shapeDraws.removeAll(keepingCapacity: true)
        backmostShapeSurface = -1

        for ball in world.snowballs {
            let attached = ball.state == .resting || ball.state == .rolling
            let ref = attached ? reference(for: ball.surfaceID, in: world) : 0
            addShape(ShapeInstance(kind: .ball, center: ball.center, size: SIMD2(repeating: ball.radius)), reference: ref)
        }
        for man in world.snowmen {
            addSnowman(man, reference: reference(for: man.surfaceID, in: world))
        }
        for clump in world.clumps {
            let r = clump.radius
            addShape(ShapeInstance(
                kind: .blob,
                center: clump.center,
                size: SIMD2(r, r * 0.85),
                rotation: clump.rotation,
                seed: Float(clump.id % 13)
            ), reference: 0)
        }
        if let position = world.shovelPosition {
            addShovel(at: position, load: world.shovelLoad)
        }

        let count = pendingShapes.count
        guard count > 0 else { return nil }
        pendingShapes.sort { a, b in
            a.reference != b.reference ? a.reference > b.reference : a.sequence < b.sequence
        }

        let stride = MemoryLayout<ShapeInstance>.stride
        guard let buffer = ensureBuffer(in: &shapeBuffers, bytes: count * stride, label: "shapes") else { return nil }
        let out = buffer.contents().bindMemory(to: ShapeInstance.self, capacity: count)
        for i in 0..<count {
            let shape = pendingShapes[i]
            out[i] = shape.instance
            if let last = shapeDraws.last, last.reference == shape.reference {
                shapeDraws[shapeDraws.count - 1].count += 1
            } else {
                shapeDraws.append(DrawRange(start: i, count: 1, reference: shape.reference))
            }
        }
        return buffer
    }

    /// Three balls, coal buttons and eyes, a carrot pointing sideways and a red scarf.
    private func addSnowman(_ man: Snowman, reference ref: UInt32) {
        let f: Float = man.facing < 0 ? -1 : 1
        let bottom = man.bottomCenter
        let middle = man.middleCenter
        let head = man.headCenter
        let r1 = man.middleRadius
        let r2 = man.headRadius

        addShape(ShapeInstance(kind: .ball, center: bottom, size: SIMD2(repeating: man.bottomRadius)), reference: ref)
        addShape(ShapeInstance(kind: .ball, center: middle, size: SIMD2(repeating: r1)), reference: ref)

        let button = SIMD2<Float>(repeating: max(1, r1 * 0.09))
        addShape(ShapeInstance(kind: .disc, center: middle + SIMD2(f * r1 * 0.12, -r1 * 0.12), size: button, color: Self.coal), reference: ref)
        addShape(ShapeInstance(kind: .disc, center: middle + SIMD2(f * r1 * 0.15, r1 * 0.28), size: button, color: Self.coal), reference: ref)

        addShape(ShapeInstance(kind: .ball, center: head, size: SIMD2(repeating: r2)), reference: ref)

        // Scarf: a band round the neck and a tail hanging on the back.
        let neckY = head.y + r2 * 0.82
        addShape(ShapeInstance(
            kind: .bar,
            center: SIMD2(head.x, neckY),
            size: SIMD2(r2 * 0.95, max(1.4, r2 * 0.2)),
            color: Self.scarf,
            rotation: 0.05 * f
        ), reference: ref)
        addShape(ShapeInstance(
            kind: .bar,
            center: SIMD2(head.x - f * r2 * 0.45, neckY + r2 * 0.45),
            size: SIMD2(max(1.2, r2 * 0.17), r2 * 0.42),
            color: Self.scarfShade,
            rotation: 0.25 * f
        ), reference: ref)

        let eye = SIMD2<Float>(repeating: max(1.1, r2 * 0.11))
        let eyeY = head.y - r2 * 0.2
        let eyeX = head.x + f * r2 * 0.14
        addShape(ShapeInstance(kind: .disc, center: SIMD2(eyeX - r2 * 0.27, eyeY), size: eye, color: Self.coal), reference: ref)
        addShape(ShapeInstance(kind: .disc, center: SIMD2(eyeX + r2 * 0.27, eyeY), size: eye, color: Self.coal), reference: ref)

        let halfLength = max(2.5, r2 * 0.42)
        addShape(ShapeInstance(
            kind: .triangle,
            center: SIMD2(head.x + f * (r2 * 0.35 + halfLength), head.y + r2 * 0.02),
            size: SIMD2(halfLength, max(1.5, r2 * 0.14)),
            color: Self.carrot,
            rotation: f > 0 ? 0.12 : Float.pi - 0.12
        ), reference: ref)
    }

    /// Blade under the cursor with a short handle; the carried heap rides on the blade.
    private func addShovel(at p: SIMD2<Float>, load: Float) {
        let bladeHalf = SnowWorld.shovelHalfWidth * 0.75
        addShape(ShapeInstance(kind: .bar, center: p + SIMD2(9, -9), size: SIMD2(1.4, 10), color: Self.handle, rotation: 0.6), reference: 0)
        guard load > 0 else {
            addShape(ShapeInstance(kind: .bar, center: p + SIMD2(0, 6), size: SIMD2(bladeHalf, 2), color: Self.blade), reference: 0)
            return
        }
        let rx = max(5, min(bladeHalf * 1.6, (load / Float.pi).squareRoot() * 1.15))
        let ry = rx * 0.6
        addShape(ShapeInstance(kind: .bar, center: p + SIMD2(0, 6), size: SIMD2(max(bladeHalf, rx * 0.9), 2), color: Self.blade), reference: 0)
        addShape(ShapeInstance(kind: .blob, center: p + SIMD2(0, 4 - ry * 0.55), size: SIMD2(rx, ry), seed: 3), reference: 0)
    }

    // MARK: Drifts

    /// Writes occluder quads and drift triangles; returns the buffer or nil when nothing to draw.
    private func fillDrifts(_ world: SnowWorld) -> MTLBuffer? {
        occluderDraws.removeAll(keepingCapacity: true)
        driftDraws.removeAll(keepingCapacity: true)

        let order = world.surfaceOrder
        let limit = min(order.count, Self.maxOrderedSurfaces)
        var backmostSnowy = -1
        var maxVertices = 0
        for k in 0..<limit {
            guard let drift = world.drifts[order[k]], !drift.isEmpty else { continue }
            backmostSnowy = k
            maxVertices += (drift.columnCount - 1) * Self.driftSubdivisions * 12
        }
        // Only surfaces in front of the back-most snowy (or snowman-carrying) one can hide anything.
        let backmost = max(backmostSnowy, min(backmostShapeSurface, limit - 1))
        guard backmost >= 0 else { return nil }
        maxVertices += backmost * 6
        guard maxVertices > 0 else { return nil }

        let vertexStride = MemoryLayout<DriftVertex>.stride
        guard let buffer = ensureBuffer(in: &driftBuffers, bytes: maxVertices * vertexStride, label: "drifts") else { return nil }
        let out = buffer.contents().bindMemory(to: DriftVertex.self, capacity: maxVertices)
        var cursor = 0

        for k in 0..<backmost {
            guard let rect = world.surfaces[order[k]]?.rect else { continue }
            let start = cursor
            let a = DriftVertex(position: SIMD2(rect.minX, rect.minY), dist: 0, t: 0)
            let b = DriftVertex(position: SIMD2(rect.maxX, rect.minY), dist: 0, t: 0)
            let c = DriftVertex(position: SIMD2(rect.minX, rect.maxY), dist: 0, t: 0)
            let d = DriftVertex(position: SIMD2(rect.maxX, rect.maxY), dist: 0, t: 0)
            out[cursor] = a
            out[cursor + 1] = b
            out[cursor + 2] = c
            out[cursor + 3] = b
            out[cursor + 4] = d
            out[cursor + 5] = c
            cursor += 6
            occluderDraws.append(DrawRange(start: start, count: 6, reference: UInt32(k + 1)))
        }

        // Back to front so a bank in front blends over one behind it.
        for k in stride(from: backmostSnowy, through: 0, by: -1) {
            let id = order[k]
            guard let drift = world.drifts[id], !drift.isEmpty, let rect = world.surfaces[id]?.rect else { continue }
            let start = cursor
            cursor = writeDrift(drift, rect: rect, seed: Float(abs(id) % 97), to: out, from: cursor)
            if cursor > start {
                driftDraws.append(DrawRange(start: start, count: cursor - start, reference: UInt32(k + 1)))
            }
        }

        return driftDraws.isEmpty && occluderDraws.isEmpty ? nil : buffer
    }

    /// Softens the simulated height map with a gaussian, adds gentle long-wavelength
    /// undulation and rounds the ends, so the bank reads as one fluffy mass.
    private func fillDisplayHeights(_ drift: Drift, seed: Float) {
        let n = drift.columnCount
        if displayHeights.count < n {
            displayHeights.append(contentsOf: repeatElement(0, count: n - displayHeights.count))
        }
        let sigma = Self.driftSmoothing / drift.columnSpacing
        let radius = max(1, min(12, Int((sigma * 2.5).rounded(.up))))
        smoothingKernel.removeAll(keepingCapacity: true)
        for k in 0...radius {
            let d = Float(k)
            smoothingKernel.append(exp(-d * d / (2 * sigma * sigma)))
        }
        let width = drift.width
        drift.heights.withUnsafeBufferPointer { src in
            smoothingKernel.withUnsafeBufferPointer { kernel in
                displayHeights.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<n {
                        var sum: Float = 0
                        var weights: Float = 0
                        for k in -radius...radius {
                            let j = i + k
                            guard j >= 0, j < n else { continue }
                            let w = kernel[abs(k)]
                            sum += src[j] * w
                            weights += w
                        }
                        var h = sum / weights
                        guard h > 0.15 else {
                            dst[i] = 0
                            continue
                        }
                        let x = drift.columnX(i)
                        // Long, low swells (wavelengths of roughly 60 and 110 pt).
                        h *= 1 + 0.07 * Self.valueNoise(x / 110, seed: seed)
                            + 0.035 * Self.valueNoise(x / 60, seed: seed + 17)
                        let edge = min(x, width - x)
                        let reach = max(3, h * 1.6)
                        if edge < reach {
                            h *= sin(max(0, edge / reach) * .pi / 2)
                        }
                        dst[i] = h
                    }
                }
            }
        }
    }

    /// Smooth 1D value noise in -1...1 with one random value per integer lattice point.
    private static func valueNoise(_ x: Float, seed: Float) -> Float {
        let cell = x.rounded(.down)
        let f = x - cell
        let u = f * f * (3 - 2 * f)
        let a = lattice(Int32(clamping: Int(cell)), seed: seed)
        let b = lattice(Int32(clamping: Int(cell) + 1), seed: seed)
        return a + (b - a) * u
    }

    private static func lattice(_ i: Int32, seed: Float) -> Float {
        var v = (UInt32(bitPattern: i) &* 0x9E37_79B1) ^ (UInt32(seed * 1013) &* 0x85EB_CA6B)
        v ^= v >> 15
        v = v &* 0x2C1B_3C6D
        v ^= v >> 12
        return Float(v & 0xFFFF) / 32767.5 - 1
    }

    /// Catmull-Rom through the display heights, `driftSubdivisions` points per column gap.
    private func fillDriftCurve(_ drift: Drift) {
        let n = drift.columnCount
        let steps = Self.driftSubdivisions
        let spacing = drift.columnSpacing
        driftCurve.removeAll(keepingCapacity: true)
        displayHeights.withUnsafeBufferPointer { h in
            for i in 0..<(n - 1) {
                let pm = h[max(0, i - 1)]
                let p0 = h[i]
                let p1 = h[i + 1]
                let p2 = h[min(n - 1, i + 2)]
                let c1 = p1 - pm
                let c2 = 2 * pm - 5 * p0 + 4 * p1 - p2
                let c3 = -pm + 3 * p0 - 3 * p1 + p2
                let x0 = drift.columnX(i)
                for k in 0..<steps {
                    let s = Float(k) / Float(steps)
                    var value = 0.5 * (2 * p0 + (c1 + (c2 + c3 * s) * s) * s)
                    var slope = 0.5 * (c1 + (2 * c2 + 3 * c3 * s) * s) / spacing
                    if value <= 0 || (p0 <= 0 && p1 <= 0) {
                        value = 0
                        slope = 0
                    }
                    driftCurve.append(SIMD3(x0 + s * spacing, value, slope))
                }
            }
            let last = max(0, h[n - 1])
            let slope = last > 0 ? (last - h[n - 2]) / spacing : 0
            driftCurve.append(SIMD3(drift.columnX(n - 1), last, slope))
        }
    }

    private func writeDrift(
        _ drift: Drift,
        rect: Rect,
        seed: Float,
        to out: UnsafeMutablePointer<DriftVertex>,
        from start: Int
    ) -> Int {
        guard drift.columnCount >= 2 else { return start }
        fillDisplayHeights(drift, seed: seed)
        fillDriftCurve(drift)

        var cursor = start
        let surfaceTop = rect.y
        // Half a point into the window so the bank sits on the edge without a seam.
        let baseY = rect.y + 0.5
        let feather = Self.feather

        // Top point and the outer end of its feather, pushed out along the outline's normal.
        func edge(_ p: SIMD3<Float>) -> (top: SIMD2<Float>, outer: SIMD2<Float>) {
            let top = SIMD2<Float>(rect.x + p.x, surfaceTop - p.y)
            // y grows down, so the outline is y = top - h(x) and its upward normal is (-h', -1).
            let normal = simd_normalize(SIMD2<Float>(-p.z, -1))
            return (top, top + normal * min(feather, p.y))
        }

        driftCurve.withUnsafeBufferPointer { curve in
            guard curve.count >= 2 else { return }
            var prev = curve[0]
            var prevEdge = edge(prev)
            for j in 1..<curve.count {
                let next = curve[j]
                let nextEdge = edge(next)
                defer {
                    prev = next
                    prevEdge = nextEdge
                }
                if prev.y <= 0 && next.y <= 0 { continue }

                let a = DriftVertex(position: prevEdge.top, dist: 0, t: 0)
                let b = DriftVertex(position: nextEdge.top, dist: 0, t: 0)
                let c = DriftVertex(position: SIMD2(prevEdge.top.x, baseY), dist: prev.y, t: 1)
                let d = DriftVertex(position: SIMD2(nextEdge.top.x, baseY), dist: next.y, t: 1)
                let fa = DriftVertex(position: prevEdge.outer, dist: 0, t: -1)
                let fb = DriftVertex(position: nextEdge.outer, dist: 0, t: -1)

                out[cursor] = a
                out[cursor + 1] = b
                out[cursor + 2] = c
                out[cursor + 3] = b
                out[cursor + 4] = d
                out[cursor + 5] = c
                out[cursor + 6] = fa
                out[cursor + 7] = fb
                out[cursor + 8] = a
                out[cursor + 9] = fb
                out[cursor + 10] = b
                out[cursor + 11] = a
                cursor += 12
            }
        }
        return cursor
    }
}
