import Foundation

/// The whole snow simulation for one screen area.
///
/// Coordinates are points with the origin at the top-left and y growing down.
/// Surfaces are kept in z-order, front-most first.
public final class SnowWorld {
    public var bounds: Rect
    public var preset: SnowfallPreset
    public var wind: Wind
    public var isPaused = false
    /// 0...1, scales the flake cap and spawn rate (low power mode).
    public var particleBudgetScale: Float = 1 {
        didSet {
            if !(particleBudgetScale >= 0 && particleBudgetScale <= 1) {
                particleBudgetScale = particleBudgetScale.isFinite ? max(0, min(1, particleBudgetScale)) : 1
            }
        }
    }

    public private(set) var flakes: [Flake] = []
    public private(set) var drifts: [Int: Drift] = [:]
    public private(set) var surfaces: [Int: Surface] = [:]
    /// Surface ids front-most first, as last passed to `setSurfaces`.
    public private(set) var surfaceOrder: [Int] = []
    /// Simulated seconds since creation (does not advance while paused).
    public private(set) var time: Float = 0

    /// Snow area (pt²) a landing flake adds, per square point of its size.
    public var depositFactor: Float = 1
    /// Max drift height for newly created drifts.
    public var driftMaxHeight: Float = 48
    /// A surface jumping farther than this (points per update) shakes some snow off.
    public var shakeThreshold: Float = 24
    /// Extra flakes allowed above the cap for snow knocked off drifts.
    public static let debrisAllowance = 400

    private struct Entry {
        let id: Int
        var rect: Rect
        let drift: Drift
    }

    private var rng: SplitMix64
    private var spawnAccumulator: Float = 0
    private var entries: [Entry] = []

    private static let swayFrequency: Float = 1.3
    private static let drag: Float = 2.5
    private static let spillChunk: Float = 8

    public init(bounds: Rect, seed: UInt64 = UInt64.random(in: .min ... .max), preset: SnowfallPreset = .steady) {
        self.bounds = bounds
        self.preset = preset
        self.wind = .calm
        self.rng = SplitMix64(seed: seed)
        flakes.reserveCapacity(SnowfallPreset.blizzard.baseFlakeCap + SnowWorld.debrisAllowance)
    }

    /// Flake cap for the current preset, bounds width and budget.
    public var flakeCap: Int {
        preset.flakeCap(forWidth: bounds.width, budgetScale: particleBudgetScale)
    }

    /// Snow lying on all surfaces, in pt².
    public var totalSnow: Float {
        var sum: Float = 0
        for entry in entries { sum += entry.drift.totalSnow }
        return sum
    }

    // MARK: - Surfaces

    /// Replaces the surface list (front-most first). New surfaces get an empty drift,
    /// moved ones keep theirs, removed ones crumble into falling clumps.
    public func setSurfaces(_ newSurfaces: [Surface]) {
        var seen = Set<Int>()
        var newEntries: [Entry] = []
        newEntries.reserveCapacity(newSurfaces.count)

        for surface in newSurfaces {
            guard seen.insert(surface.id).inserted else { continue }
            let drift: Drift
            if let existing = drifts[surface.id], let old = surfaces[surface.id] {
                drift = existing
                if old.rect != surface.rect {
                    surfaceChanged(id: surface.id, drift: drift, from: old.rect, to: surface.rect)
                }
            } else {
                drift = Drift(width: surface.rect.width, maxHeight: driftMaxHeight)
            }
            newEntries.append(Entry(id: surface.id, rect: surface.rect, drift: drift))
        }

        for entry in entries where !seen.contains(entry.id) {
            crumble(entry.drift, rect: entry.rect)
        }

        entries = newEntries
        var newDrifts: [Int: Drift] = [:]
        var newSurfaceMap: [Int: Surface] = [:]
        for entry in newEntries {
            newDrifts[entry.id] = entry.drift
            newSurfaceMap[entry.id] = Surface(id: entry.id, rect: entry.rect)
        }
        drifts = newDrifts
        surfaces = newSurfaceMap
        surfaceOrder = newEntries.map { $0.id }
    }

    private func surfaceChanged(id: Int, drift: Drift, from old: Rect, to new: Rect) {
        if abs(new.width - old.width) > 0.5 {
            let lost = drift.resize(width: new.width)
            if lost > 0 {
                let x0 = new.maxX
                let x1 = max(x0 + 1, new.x + old.width)
                emitPieces(amount: lost, maxPieces: 40, ignoring: nil) { rng in
                    let position = SIMD2<Float>(rng.float(in: x0...x1), new.y - rng.unit() * 6)
                    let velocity = SIMD2<Float>(rng.signedUnit() * 20, rng.float(in: 0...30))
                    return (position, velocity)
                }
            }
        }

        let dx = new.x - old.x
        let dy = new.y - old.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance > shakeThreshold {
            let fraction = min(0.6, 0.15 + (distance - shakeThreshold) / 400)
            let removed = drift.remove(fraction: fraction)
            emitPieces(fromDrift: drift, rect: new, amount: removed, maxPieces: 80, ignoring: id)
        }
    }

    private func crumble(_ drift: Drift, rect: Rect) {
        let amount = drift.totalSnow
        emitPieces(fromDrift: drift, rect: rect, amount: amount, maxPieces: 150, ignoring: nil)
        drift.clear()
    }

    // MARK: - Simulation

    public func step(dt: Float) {
        guard !isPaused, dt > 0, dt.isFinite else { return }
        let dt = min(dt, 0.1)
        time += dt
        spawn(dt: dt)
        integrate(dt: dt)
        settleDrifts()
    }

    private func spawn(dt: Float) {
        let cap = flakeCap
        let rate = preset.spawnRatePer1000 * max(0, bounds.width) / 1000 * particleBudgetScale
        spawnAccumulator += rate * dt
        while spawnAccumulator >= 1 {
            guard flakes.count < cap else {
                spawnAccumulator = min(spawnAccumulator, 1)
                return
            }
            spawnAccumulator -= 1
            flakes.append(makeFlake())
        }
    }

    private func makeFlake() -> Flake {
        let sizes = preset.sizeRange
        let size = rng.float(in: sizes)
        let fall = rng.float(in: preset.fallSpeedRange)
        // Spawn wider on the upwind side so the screen stays evenly covered.
        let travelTime = max(0, bounds.height) / max(1, fall * max(0.25, wind.fallMultiplier))
        let shift = max(-bounds.width, min(bounds.width, wind.horizontalSpeed * travelTime))
        let minX = bounds.x - max(0, shift)
        let maxX = bounds.maxX - min(0, shift)
        let x = minX + (maxX - minX) * rng.unit()
        let y = bounds.y - size - rng.unit() * 12
        let sizeT = sizes.upperBound > sizes.lowerBound
            ? (size - sizes.lowerBound) / (sizes.upperBound - sizes.lowerBound)
            : 0.5
        return Flake(
            position: SIMD2(x, y),
            velocity: SIMD2(wind.horizontalSpeed, fall * wind.fallMultiplier),
            size: size,
            rotation: rng.unit() * 2 * .pi,
            spin: rng.signedUnit() * 1.5,
            opacity: 0.5 + 0.3 * sizeT + 0.2 * rng.unit(),
            phase: rng.unit() * 2 * .pi,
            swayAmplitude: rng.float(in: 6...22),
            fallSpeed: fall
        )
    }

    private func integrate(dt: Float) {
        let windX = wind.horizontalSpeed
        let fallMultiplier = max(0.25, wind.fallMultiplier)
        let k = min(1, SnowWorld.drag * dt)
        let swayTime = time * SnowWorld.swayFrequency
        let left = bounds.x - 20
        let right = bounds.maxX + 20
        let farLeft = bounds.x - bounds.width - 40
        let farRight = bounds.maxX + bounds.width + 40
        let bottom = bounds.maxY + 20

        var i = 0
        while i < flakes.count {
            var f = flakes[i]
            let prevY = f.position.y
            let sway = sin(swayTime + f.phase) * f.swayAmplitude
            let target = SIMD2<Float>(windX + sway, f.fallSpeed * fallMultiplier)
            f.velocity += (target - f.velocity) * k
            f.position += f.velocity * dt
            f.rotation += f.spin * dt

            let p = f.position
            let gone = p.y > bottom
                || p.x < farLeft || p.x > farRight
                || (p.x < left && f.velocity.x <= 0)
                || (p.x > right && f.velocity.x >= 0)
            if gone || (f.velocity.y > 0 && land(f, previousY: prevY)) {
                flakes[i] = flakes[flakes.count - 1]
                flakes.removeLast()
                continue
            }
            flakes[i] = f
            i += 1
        }
    }

    /// Checks the front-most surface under the flake. Returns true if it landed.
    private func land(_ f: Flake, previousY: Float) -> Bool {
        let p = f.position
        for entry in entries {
            let r = entry.rect
            guard p.x >= r.x, p.x <= r.maxX else { continue }
            if entry.id != f.ignoredSurfaceID {
                let localX = p.x - r.x
                let top = r.y - entry.drift.height(atX: localX)
                if previousY <= top && p.y >= top {
                    entry.drift.deposit(atX: localX, amount: f.size * f.size * depositFactor)
                    return true
                }
            }
            // Behind this window: covered parts of windows further back are out of reach.
            if p.y > r.y && p.y < r.maxY { return false }
        }
        return false
    }

    private func settleDrifts() {
        for entry in entries {
            let drift = entry.drift
            drift.settle()
            let r = entry.rect
            while drift.pendingSpillLeft >= SnowWorld.spillChunk {
                drift.pendingSpillLeft -= SnowWorld.spillChunk
                emitSpill(at: SIMD2(r.x - 1, r.y - 1), direction: -1, id: entry.id)
            }
            while drift.pendingSpillRight >= SnowWorld.spillChunk {
                drift.pendingSpillRight -= SnowWorld.spillChunk
                emitSpill(at: SIMD2(r.maxX + 1, r.y - 1), direction: 1, id: entry.id)
            }
        }
    }

    private func emitSpill(at position: SIMD2<Float>, direction: Float, id: Int) {
        let velocity = SIMD2<Float>(direction * rng.float(in: 5...20), rng.float(in: 5...20))
        emitDebris(at: position, velocity: velocity, size: SnowWorld.spillChunk.squareRoot(), ignoring: id)
    }

    // MARK: - Tools

    /// Mitten: removes snow under the circle on every drift; the snow is thrown sideways as clumps.
    public func sweep(at point: SIMD2<Float>, radius: Float) {
        guard radius > 0 else { return }
        for entry in entries {
            let r = entry.rect
            guard point.x + radius >= r.x, point.x - radius <= r.maxX,
                  point.y + radius >= r.y - entry.drift.maxHeight, point.y - radius <= r.y
            else { continue }
            let removed = entry.drift.sweep(center: point - r.origin, radius: radius)
            guard removed > 0 else { continue }
            let topY = min(point.y, r.y - 1)
            let spread = radius * 0.8
            emitPieces(amount: removed, maxPieces: 12, ignoring: entry.id) { rng in
                let offset = rng.signedUnit() * spread
                let x = max(r.x, min(r.maxX, point.x + offset))
                let direction: Float = offset >= 0 ? 1 : -1
                let velocity = SIMD2<Float>(direction * rng.float(in: 70...170), -rng.float(in: 40...130))
                return (SIMD2<Float>(x, topY), velocity)
            }
        }
    }

    /// Shovel: removes all lying snow and all falling flakes. Snowfall continues.
    public func clearAll() {
        for entry in entries { entry.drift.clear() }
        flakes.removeAll(keepingCapacity: true)
        spawnAccumulator = 0
    }

    // MARK: - Debris

    private var debrisLimit: Int {
        flakeCap + Int(Float(SnowWorld.debrisAllowance) * max(0.25, particleBudgetScale))
    }

    private func emitDebris(at position: SIMD2<Float>, velocity: SIMD2<Float>, size: Float, ignoring id: Int?) {
        guard flakes.count < debrisLimit else { return }
        let fall = rng.float(in: 60...110)
        flakes.append(Flake(
            position: position,
            velocity: velocity,
            size: size,
            rotation: rng.unit() * 2 * .pi,
            spin: rng.signedUnit() * 4,
            opacity: 0.85 + 0.15 * rng.unit(),
            phase: rng.unit() * 2 * .pi,
            swayAmplitude: rng.float(in: 0...4),
            fallSpeed: fall,
            isDebris: true,
            ignoredSurfaceID: id
        ))
    }

    /// Splits `amount` pt² into clumps whose areas add up to roughly the same total.
    /// `make` returns each clump's position and velocity.
    private func emitPieces(
        amount: Float,
        maxPieces: Int,
        ignoring id: Int?,
        make: (inout SplitMix64) -> (SIMD2<Float>, SIMD2<Float>)
    ) {
        guard amount > 0.5, amount.isFinite, maxPieces > 0 else { return }
        let count = max(1, min(maxPieces, Int(min(Float(maxPieces), (amount / 14).rounded(.up)))))
        let size = max(2, min(6, (amount / Float(count)).squareRoot()))
        for _ in 0..<count {
            let (position, velocity) = make(&rng)
            emitDebris(at: position, velocity: velocity, size: size, ignoring: id)
        }
    }

    /// Clumps sampled from where the drift actually has snow.
    private func emitPieces(fromDrift drift: Drift, rect: Rect, amount: Float, maxPieces: Int, ignoring id: Int?) {
        let peak = drift.peakHeight
        let width = drift.width
        emitPieces(amount: amount, maxPieces: maxPieces, ignoring: id) { rng in
            var x = rng.unit() * width
            if peak > 0 {
                // Rejection sampling so clumps come from the thick parts.
                var tries = 0
                while tries < 8 && rng.unit() * peak > drift.height(atX: x) {
                    x = rng.unit() * width
                    tries += 1
                }
            }
            let h = drift.height(atX: x)
            let position = SIMD2<Float>(rect.x + x, rect.y - h * rng.unit() - 1)
            let velocity = SIMD2<Float>(rng.signedUnit() * 25, rng.float(in: 0...40))
            return (position, velocity)
        }
    }
}
