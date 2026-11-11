import Foundation

/// The shovel: `scoop` shaves snow off the drift under the blade into `shovelLoad`,
/// `dump` throws the whole load as one `SnowClump`. A clump that lands on a drift is
/// added to it as a tall pile (which then relaxes to the angle of repose); one that lands
/// nowhere bursts into debris at the bottom of the bounds. Scooped snow equals dumped snow.
extension SnowWorld {
    /// Most snow the shovel carries, in pt².
    public static let shovelCapacity: Float = 2500
    /// Half the blade width, in points.
    public static let shovelHalfWidth: Float = 20

    static let clumpGravity: Float = 1000
    static let clumpMaxFallSpeed: Float = 900
    static let clumpMaxThrowSpeed: Float = 900

    /// Room left on the shovel, in pt².
    public var shovelRoom: Float { max(0, SnowWorld.shovelCapacity - shovelLoad) }

    /// Scrapes up to `depth` points off the top of the front-most drift under `point`,
    /// across a blade `2 * halfWidth` wide, onto the shovel. Returns the pt² scooped.
    @discardableResult
    public func scoop(at point: SIMD2<Float>, halfWidth: Float = SnowWorld.shovelHalfWidth, depth: Float = 10) -> Float {
        guard !isPaused, point.x.isFinite, point.y.isFinite else { return 0 }
        let room = shovelRoom
        guard room > 0.01,
              let surfaceID = driftSurfaceID(at: point, tolerance: 12, minHeight: 0.05),
              let drift = drifts[surfaceID],
              let rect = surfaces[surfaceID]?.rect
        else { return 0 }
        let taken = drift.scrape(aroundX: point.x - rect.x, halfWidth: halfWidth, depth: depth, limit: room)
        shovelLoad = min(SnowWorld.shovelCapacity, shovelLoad + taken)
        return taken
    }

    /// Throws the whole shovel load from `point` with `velocity` (pt/s) as one clump.
    /// Returns the clump id, or nil if the shovel was empty.
    @discardableResult
    public func dump(at point: SIMD2<Float>, velocity: SIMD2<Float>) -> Int? {
        let amount = shovelLoad
        shovelLoad = 0
        guard amount > 0.01, point.x.isFinite, point.y.isFinite else { return nil }

        var v = velocity.x.isFinite && velocity.y.isFinite ? velocity * 0.6 : .zero
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        if speed > SnowWorld.clumpMaxThrowSpeed {
            v *= SnowWorld.clumpMaxThrowSpeed / speed
        }

        // Dumped right onto a bank: start just above its top so the clump lands there.
        let radius = SnowClump.radius(forAmount: amount)
        var center = point
        for entry in entries {
            let r = entry.rect
            guard point.x >= r.x, point.x <= r.maxX else { continue }
            let top = r.y - entry.drift.height(atX: point.x - r.x)
            if point.y >= top - radius, point.y <= r.y + 12 {
                center.y = min(point.y, top - radius * 0.6 - 0.5)
                break
            }
            if r.contains(point) { break }
        }

        let clump = SnowClump(
            id: makeObjectID(),
            center: center,
            velocity: v,
            amount: amount,
            rotation: rng.unit() * 2 * Float.pi,
            spin: rng.signedUnit() * 3
        )
        clumps.append(clump)
        return clump.id
    }

    /// Moves whatever is on the shovel over to `other` (cursor crossed to another screen).
    public func transferShovelLoad(to other: SnowWorld) {
        guard other !== self, shovelLoad > 0 else { return }
        let moved = min(shovelLoad, other.shovelRoom)
        other.shovelLoad += moved
        shovelLoad = 0
        other.shovelPosition = shovelPosition
        shovelPosition = nil
    }

    // MARK: - Simulation

    func stepClumps(dt: Float) {
        guard !clumps.isEmpty else { return }
        var i = 0
        while i < clumps.count {
            var c = clumps[i]
            let radius = c.radius
            let previousBottom = c.center.y + radius * 0.6
            c.velocity.y = min(SnowWorld.clumpMaxFallSpeed, c.velocity.y + SnowWorld.clumpGravity * dt)
            c.velocity.x *= exp(-0.6 * dt)
            c.center += c.velocity * dt
            c.rotation += c.spin * dt
            clumps[i] = c

            if c.velocity.y > 0, land(clumpAt: i, previousBottom: previousBottom) {
                clumps.remove(at: i)
                continue
            }
            if c.center.y + radius * 0.6 >= bounds.maxY {
                let y = min(c.center.y, bounds.maxY - radius * 0.5)
                burst(amount: c.amount, at: SIMD2(c.center.x, y), radius: radius)
                clumps.remove(at: i)
                continue
            }
            if c.center.x < bounds.x - 300 || c.center.x > bounds.maxX + 300 {
                clumps.remove(at: i)
                continue
            }
            i += 1
        }
    }

    /// Adds the clump to the front-most drift it crosses. Returns true if it landed.
    private func land(clumpAt i: Int, previousBottom: Float) -> Bool {
        let c = clumps[i]
        let bottom = c.center.y + c.radius * 0.6
        for entry in entries {
            let r = entry.rect
            guard c.center.x >= r.x, c.center.x <= r.maxX else { continue }
            let localX = c.center.x - r.x
            let top = r.y - entry.drift.height(atX: localX)
            if previousBottom <= top + 6, bottom >= top {
                let accepted = entry.drift.depositPile(atX: localX, amount: c.amount)
                let rest = c.amount - accepted
                if rest > 0.5 {
                    // The drift is full there: the rest slides off as debris.
                    burst(amount: rest, at: SIMD2(c.center.x, top - 2), radius: c.radius)
                }
                return true
            }
            // Behind this window: surfaces further back are out of reach.
            if c.center.y > r.y, c.center.y < r.maxY { return false }
        }
        return false
    }

    private func burst(amount: Float, at center: SIMD2<Float>, radius: Float) {
        let spread = max(2, radius * 0.7)
        emitPieces(amount: amount, maxPieces: 40, ignoring: nil) { rng in
            let offset = SIMD2<Float>(rng.signedUnit() * spread, rng.signedUnit() * spread * 0.5)
            let velocity = SIMD2<Float>(rng.signedUnit() * 160, -rng.float(in: 60...260))
            return (center + offset, velocity)
        }
    }
}
