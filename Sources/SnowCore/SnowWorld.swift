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

    /// Snowballs being rolled, falling or lying on surfaces (see `SnowWorld+Snowballs`).
    public internal(set) var snowballs: [Snowball] = []
    /// Finished snowmen standing on surfaces.
    public internal(set) var snowmen: [Snowman] = []
    /// Dumped shovel loads in flight (see `SnowWorld+Shovel`).
    public internal(set) var clumps: [SnowClump] = []
    /// Snow carried on the shovel, in pt².
    public internal(set) var shovelLoad: Float = 0
    /// Where the shovel blade is drawn; nil hides it. Set by the input layer.
    public var shovelPosition: SIMD2<Float>?
    var nextObjectID = 1

    struct Entry {
        let id: Int
        var rect: Rect
        let drift: Drift
    }

    /// A surface missing from the latest `setSurfaces`. Its drift and the snow objects
    /// standing on it are kept out of sight (not drawn, not hit) so they come back with it.
    struct DormantSurface {
        var rect: Rect
        let drift: Drift
        /// World `time` when the surface went missing.
        let since: Float
        var snowballs: [Snowball] = []
        var snowmen: [Snowman] = []
    }

    /// Surfaces that went missing, by id (see `setSurfaces`).
    var dormant: [Int: DormantSurface] = [:]

    /// Seconds a missing surface counts as a tracker glitch: if it comes back within this
    /// time, the move from its last rect is applied as usual (a far jump still shakes snow off).
    public var missingGrace: Float = 2
    /// Seconds a missing surface keeps its snow (another Space, ⌘H, minimized). After that
    /// the snow is forgotten without debris: the window is not on screen to drop it from.
    public var dormantLifetime: Float = 600
    /// Most missing surfaces kept at once; the oldest is forgotten first.
    public static let maxDormantSurfaces = 64

    /// Ids of missing surfaces whose snow is kept until they return.
    public var dormantSurfaceIDs: Set<Int> { Set(dormant.keys) }

    var rng: SplitMix64
    private var spawnAccumulator: Float = 0
    var entries: [Entry] = []

    private static let swayFrequency: Float = 1.3
    private static let drag: Float = 2.5
    /// Spilled snow (pt²) that makes one clump falling off a drift end.
    private static let spillClump: Float = 24
    /// Spill waiting at one end beyond this is dropped instead of falling.
    private static let spillBacklog: Float = 48
    /// Seconds between two clumps leaving the same drift end.
    private static let spillInterval: ClosedRange<Float> = 1.2...3.5

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

    /// Replaces the surface list (front-most first). New surfaces get an empty drift and
    /// moved ones keep theirs. Missing ones go dormant: the window may only be on another
    /// Space, hidden, minimized or skipped by one poll, so its drift, resting snowballs and
    /// snowmen are put aside (not drawn, not hit) and come back when the id returns within
    /// `dormantLifetime`.
    public func setSurfaces(_ newSurfaces: [Surface]) {
        var seen = Set<Int>()
        var shaken: [Int: SIMD2<Float>] = [:]
        var newEntries: [Entry] = []
        var woken: [DormantSurface] = []
        newEntries.reserveCapacity(newSurfaces.count)

        for surface in newSurfaces {
            guard seen.insert(surface.id).inserted else { continue }
            let drift: Drift
            var previous: Rect?
            if let existing = drifts[surface.id], let old = surfaces[surface.id] {
                drift = existing
                previous = old.rect
            } else if let sleeping = dormant.removeValue(forKey: surface.id) {
                drift = sleeping.drift
                woken.append(sleeping)
                if time - sleeping.since <= missingGrace {
                    previous = sleeping.rect
                } else if abs(surface.rect.width - sleeping.rect.width) > 0.5 {
                    // Back after a while, maybe somewhere else: placed as it is now, no shake.
                    drift.resize(width: surface.rect.width)
                }
            } else {
                drift = Drift(width: surface.rect.width, maxHeight: driftMaxHeight)
            }
            if let old = previous, old != surface.rect {
                surfaceChanged(id: surface.id, drift: drift, from: old, to: surface.rect)
                let shift = SIMD2<Float>(surface.rect.x - old.x, surface.rect.y - old.y)
                if (shift.x * shift.x + shift.y * shift.y).squareRoot() > shakeThreshold {
                    shaken[surface.id] = shift
                }
            }
            newEntries.append(Entry(id: surface.id, rect: surface.rect, drift: drift))
        }

        var removed = Set<Int>()
        for entry in entries where !seen.contains(entry.id) {
            removed.insert(entry.id)
            dormant[entry.id] = DormantSurface(rect: entry.rect, drift: entry.drift, since: time)
        }
        if !removed.isEmpty {
            stashSnowObjects(on: removed)
            trimDormant()
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

        if !woken.isEmpty {
            restoreSnowObjects(from: woken)
        }
        if !snowballs.isEmpty || !snowmen.isEmpty {
            snowObjectsSurfacesChanged(removed: removed, shaken: shaken)
        }
    }

    /// The windows behind `ids` were closed, not just moved off screen. A surface that went
    /// missing within `missingGrace` crumbles where it stood: its snow falls as debris and
    /// its snowballs and snowmen fall. One missing for longer is forgotten without debris,
    /// since nothing is on screen there any more. Ids still on screen are left alone.
    public func closeSurfaces(_ ids: Set<Int>) {
        for id in ids {
            guard let record = dormant.removeValue(forKey: id) else { continue }
            guard time - record.since <= missingGrace else { continue }
            let drift = record.drift
            emitPieces(fromDrift: drift, rect: record.rect, amount: drift.totalSnow, maxPieces: 150, ignoring: nil)
            drift.clear()
            dropStashedSnowObjects(record)
        }
    }

    /// Forgets the oldest dormant surfaces beyond `maxDormantSurfaces`.
    private func trimDormant() {
        while dormant.count > SnowWorld.maxDormantSurfaces {
            guard let oldest = dormant.min(by: { $0.value.since < $1.value.since })?.key else { return }
            dormant[oldest] = nil
        }
    }

    /// Forgets dormant surfaces missing for longer than `dormantLifetime` (and the grace).
    private func expireDormant() {
        guard !dormant.isEmpty else { return }
        let limit = max(missingGrace, dormantLifetime)
        let now = time
        let expired = dormant.filter { now - $0.value.since > limit }.map { $0.key }
        for id in expired { dormant[id] = nil }
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

    // MARK: - Simulation

    public func step(dt: Float) {
        guard !isPaused, dt > 0, dt.isFinite else { return }
        let dt = min(dt, 0.1)
        time += dt
        expireDormant()
        spawn(dt: dt)
        integrate(dt: dt)
        settleDrifts(dt: dt)
        stepSnowObjects(dt: dt)
        stepClumps(dt: dt)
    }

    /// How far upwind of the bounds a flake falling at `fall` pt/s has to start to drift
    /// across the whole screen: positive when the wind blows right, at most one bounds width.
    private func upwindShift(fall: Float) -> Float {
        let travelTime = max(0, bounds.height) / max(1, fall * max(0.25, wind.fallMultiplier))
        let width = max(0, bounds.width)
        return max(-width, min(width, wind.horizontalSpeed * travelTime))
    }

    /// Width of the spawn band (bounds plus the upwind extension) over the bounds width,
    /// 1...2. The spawn rate scales with it so the screen gets the same density in wind.
    var spawnWidthFactor: Float {
        let width = bounds.width
        guard width > 0, width.isFinite else { return 1 }
        let fall = preset.fallSpeedRange
        let shift = upwindShift(fall: (fall.lowerBound + fall.upperBound) * 0.5)
        return max(1, min(2, (width + abs(shift)) / width))
    }

    /// Flake cap including the flakes still upwind of the bounds. A flake spawned upwind
    /// spends part of its life off screen before it enters, but is culled soon after it
    /// leaves downwind, so on average it needs half the band extension, not all of it.
    var spawnCap: Int {
        Int((Float(flakeCap) * (1 + spawnWidthFactor) * 0.5).rounded())
    }

    private func spawn(dt: Float) {
        let widthFactor = spawnWidthFactor
        let cap = spawnCap
        let rate = preset.spawnRatePer1000 * max(0, bounds.width) / 1000 * particleBudgetScale * widthFactor
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
        let shift = upwindShift(fall: fall)
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

            // Off the side and the wind keeps it there. The flake's own velocity is not
            // enough: sway briefly turns it back, which culled flakes spawned upwind.
            let p = f.position
            let gone = p.y > bottom
                || p.x < farLeft || p.x > farRight
                || (p.x < left && windX <= 0)
                || (p.x > right && windX >= 0)
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

    /// Settles every drift and lets what slid off the ends fall.
    ///
    /// A full drift sheds snow off both ends every frame. Falling as one flake per chunk at
    /// the exact edge, that drew a dotted line down each window side, so spill now leaves
    /// as an occasional clump thrown outwards from a jittered spot, and the rest is dropped.
    private func settleDrifts(dt: Float) {
        for entry in entries {
            let drift = entry.drift
            // A drift nothing touched since it last came to rest has nothing to move.
            if !drift.isSettled {
                drift.settle()
            }
            let r = entry.rect
            drift.spillCooldownLeft -= dt
            drift.spillCooldownRight -= dt
            if drift.pendingSpillLeft >= SnowWorld.spillClump, drift.spillCooldownLeft <= 0 {
                drift.pendingSpillLeft -= SnowWorld.spillClump
                drift.spillCooldownLeft = rng.float(in: SnowWorld.spillInterval)
                emitSpill(edgeX: r.x, top: r.y, direction: -1, id: entry.id)
            }
            if drift.pendingSpillRight >= SnowWorld.spillClump, drift.spillCooldownRight <= 0 {
                drift.pendingSpillRight -= SnowWorld.spillClump
                drift.spillCooldownRight = rng.float(in: SnowWorld.spillInterval)
                emitSpill(edgeX: r.maxX, top: r.y, direction: 1, id: entry.id)
            }
            drift.pendingSpillLeft = min(drift.pendingSpillLeft, SnowWorld.spillBacklog)
            drift.pendingSpillRight = min(drift.pendingSpillRight, SnowWorld.spillBacklog)
        }
    }

    private func emitSpill(edgeX: Float, top: Float, direction: Float, id: Int) {
        let position = SIMD2<Float>(edgeX + direction * rng.float(in: 1...5), top - rng.float(in: 1...4))
        let velocity = SIMD2<Float>(direction * rng.float(in: 40...110), -rng.float(in: 5...45))
        let size = rng.float(in: 0.8...1.1) * SnowWorld.spillClump.squareRoot()
        emitDebris(at: position, velocity: velocity, size: size, ignoring: id)
    }

    // MARK: - Tools

    /// Mitten: removes snow under the circle on every drift; the snow is thrown sideways as clumps.
    public func sweep(at point: SIMD2<Float>, radius: Float) {
        sweep(at: point, radius: radius, direction: .zero)
    }

    /// Mitten moving in `direction` (any length; the cursor velocity works): the snow is
    /// kicked mostly that way. A zero direction throws it to both sides.
    public func sweep(at point: SIMD2<Float>, radius: Float, direction: SIMD2<Float>) {
        guard radius > 0, radius.isFinite, point.x.isFinite, point.y.isFinite else { return }
        let length = direction.x.isFinite && direction.y.isFinite
            ? (direction.x * direction.x + direction.y * direction.y).squareRoot()
            : 0
        let heading: SIMD2<Float>? = length > 0.01 ? direction / length : nil
        for (k, entry) in entries.enumerated() {
            let r = entry.rect
            if point.x + radius >= r.x, point.x - radius <= r.maxX,
               point.y + radius >= r.y - entry.drift.maxHeight, point.y - radius <= r.y,
               !isSweepCovered(entry, index: k, near: point.x) {
                sweepDrift(entry, at: point, radius: radius, heading: heading)
            }
            // A window under the cursor hides everything behind it.
            if r.contains(point) { break }
        }
    }

    /// True if the part of the drift under `x` is hidden behind a window further front.
    private func isSweepCovered(_ entry: Entry, index: Int, near x: Float) -> Bool {
        let r = entry.rect
        let localX = max(0, min(r.width, x - r.x))
        let h = max(1, entry.drift.height(atX: localX))
        return isCovered(SIMD2(r.x + localX, r.y - h * 0.5), byFirst: index)
    }

    private func sweepDrift(_ entry: Entry, at point: SIMD2<Float>, radius: Float, heading: SIMD2<Float>?) {
        let r = entry.rect
        let removed = entry.drift.sweep(center: point - r.origin, radius: radius)
        guard removed > 0 else { return }
        let topY = min(point.y, r.y - 1)
        let spread = radius * 0.8
        emitPieces(amount: removed, maxPieces: 12, ignoring: entry.id) { rng in
            let offset = rng.signedUnit() * spread
            let x = max(r.x, min(r.maxX, point.x + offset))
            if let heading {
                let side = SIMD2<Float>(-heading.y, heading.x) * (rng.signedUnit() * 45)
                let forward: SIMD2<Float> = heading * rng.float(in: 90...200)
                let lift = SIMD2<Float>(0, -rng.float(in: 30...90))
                let velocity: SIMD2<Float> = forward + side + lift
                return (SIMD2<Float>(x, topY), velocity)
            }
            let direction: Float = offset >= 0 ? 1 : -1
            let velocity = SIMD2<Float>(direction * rng.float(in: 70...170), -rng.float(in: 40...130))
            return (SIMD2<Float>(x, topY), velocity)
        }
    }

    /// «Очистить сугробы»: removes all lying snow, falling flakes, snowballs, snowmen,
    /// dumped clumps and the shovel load. Snowfall continues.
    public func clearAll() {
        for entry in entries { entry.drift.clear() }
        dormant.removeAll()
        flakes.removeAll(keepingCapacity: true)
        snowballs.removeAll()
        snowmen.removeAll()
        clumps.removeAll()
        shovelLoad = 0
        spawnAccumulator = 0
    }

    // MARK: - Debris

    var debrisLimit: Int {
        spawnCap + Int(Float(SnowWorld.debrisAllowance) * max(0.25, particleBudgetScale))
    }

    func emitDebris(at position: SIMD2<Float>, velocity: SIMD2<Float>, size: Float, ignoring id: Int?) {
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
    func emitPieces(
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
    func emitPieces(fromDrift drift: Drift, rect: Rect, amount: Float, maxPieces: Int, ignoring id: Int?) {
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
