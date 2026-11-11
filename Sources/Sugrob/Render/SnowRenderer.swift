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
/// Buffers are triple-buffered behind a semaphore and grow on demand, so steady-state
/// frames allocate nothing.
@MainActor
final class SnowRenderer {
    static let maxFramesInFlight = 3
    /// Stencil is 8 bit and 255 is the clear value, so this many surfaces can be ordered.
    static let maxOrderedSurfaces = 254
    /// Height of the anti-aliasing strip above the top edge, in points.
    static let feather: Float = 1.2

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
    private var stencilTexture: MTLTexture?

    private var displayHeights: [Float] = []
    private var occluderDraws: [DrawRange] = []
    private var driftDraws: [DrawRange] = []

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

        if let driftBuffer, !driftDraws.isEmpty {
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
            maxVertices += (drift.columnCount - 1) * 12
        }
        guard backmostSnowy >= 0 else { return nil }
        // Only surfaces in front of the back-most snowy one can hide anything.
        maxVertices += backmostSnowy * 6

        let vertexStride = MemoryLayout<DriftVertex>.stride
        guard let buffer = ensureBuffer(in: &driftBuffers, bytes: maxVertices * vertexStride, label: "drifts") else { return nil }
        let out = buffer.contents().bindMemory(to: DriftVertex.self, capacity: maxVertices)
        var cursor = 0

        for k in 0..<backmostSnowy {
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

        return driftDraws.isEmpty ? nil : buffer
    }

    /// Smooths the simulated height map a little, adds lumps and rounds the ends,
    /// so the bank looks soft instead of like a bar chart.
    private func fillDisplayHeights(_ drift: Drift, seed: Float) {
        let n = drift.columnCount
        if displayHeights.count < n {
            displayHeights.append(contentsOf: repeatElement(0, count: n - displayHeights.count))
        }
        let width = drift.width
        drift.heights.withUnsafeBufferPointer { src in
            displayHeights.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    var sum: Float = 0
                    var weights: Float = 0
                    for k in -2...2 {
                        let j = i + k
                        guard j >= 0, j < n else { continue }
                        let w = Float(3 - abs(k))
                        sum += src[j] * w
                        weights += w
                    }
                    var h = sum / weights
                    guard h > 0.15 else {
                        dst[i] = 0
                        continue
                    }
                    let x = drift.columnX(i)
                    h *= 1 + 0.08 * sin(x * 0.17 + seed) + 0.05 * sin(x * 0.43 + seed * 1.7)
                    let edge = min(x, width - x)
                    let reach = max(2, h * 1.2)
                    if edge < reach {
                        h *= max(0, edge / reach).squareRoot()
                    }
                    dst[i] = h
                }
            }
        }
    }

    private func writeDrift(
        _ drift: Drift,
        rect: Rect,
        seed: Float,
        to out: UnsafeMutablePointer<DriftVertex>,
        from start: Int
    ) -> Int {
        let n = drift.columnCount
        guard n >= 2 else { return start }
        fillDisplayHeights(drift, seed: seed)

        var cursor = start
        let surfaceTop = rect.y
        // Half a point into the window so the bank sits on the edge without a seam.
        let baseY = rect.y + 0.5
        let feather = Self.feather

        displayHeights.withUnsafeBufferPointer { h in
            for i in 0..<(n - 1) {
                let h0 = h[i]
                let h1 = h[i + 1]
                if h0 <= 0 && h1 <= 0 { continue }
                let x0 = rect.x + drift.columnX(i)
                let x1 = rect.x + drift.columnX(i + 1)
                let top0 = surfaceTop - h0
                let top1 = surfaceTop - h1
                let f0 = min(feather, h0)
                let f1 = min(feather, h1)

                let a = DriftVertex(position: SIMD2(x0, top0), dist: 0, t: 0)
                let b = DriftVertex(position: SIMD2(x1, top1), dist: 0, t: 0)
                let c = DriftVertex(position: SIMD2(x0, baseY), dist: h0, t: 1)
                let d = DriftVertex(position: SIMD2(x1, baseY), dist: h1, t: 1)
                let fa = DriftVertex(position: SIMD2(x0, top0 - f0), dist: 0, t: -1)
                let fb = DriftVertex(position: SIMD2(x1, top1 - f1), dist: 0, t: -1)

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
