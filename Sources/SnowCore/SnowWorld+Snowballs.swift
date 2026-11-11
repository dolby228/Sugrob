import Foundation

/// Snowballs and snowmen.
///
/// A ball is packed from a drift with `beginRoll`, grows while `rollBall` drags it along
/// snow (its area is taken from the drift, so snow is conserved), and after `releaseBall`
/// it falls until it lands on a drift or on the top ball of a stack. Three stacked balls
/// turn into a `Snowman`. Resting balls and snowmen ride along with their surface; a hard
/// shake or a vanished surface knocks them off, and a ball that reaches the bottom of the
/// bounds bursts into debris flakes.
extension SnowWorld {
    public static let minSnowballRadius: Float = 4
    public static let maxSnowballRadius: Float = 28
    /// Least snow height (pt) under the cursor needed to pack a new ball.
    public static let minSnowToRoll: Float = 2
    /// Live snowballs (any state) allowed at once; `beginRoll` refuses past this.
    public static let maxSnowballs = 24
    /// Oldest snowmen crumble when more than this many stand.
    public static let maxSnowmen = 8

    static let snowballGravity: Float = 1100
    static let snowballMaxFallSpeed: Float = 900
    static let snowballMaxReleaseSpeed: Float = 700
    /// Part of the drift height a resting ball sinks into.
    static let snowballSink: Float = 0.7

    // MARK: - Public API

    /// Starts rolling at `point`: picks up the top ball of a resting stack under the
    /// cursor, or packs a new ball from a drift with enough snow. Returns the ball id.
    @discardableResult
    public func beginRoll(at point: SIMD2<Float>) -> Int? {
        guard !isPaused, point.x.isFinite, point.y.isFinite else { return nil }

        if let i = pickableBallIndex(near: point) {
            detachFromParent(i)
            snowballs[i].state = .held
            snowballs[i].surfaceID = nil
            snowballs[i].velocity = .zero
            let id = snowballs[i].id
            rollBall(id, to: point)
            return id
        }

        guard snowballs.count < SnowWorld.maxSnowballs,
              let surfaceID = driftSurfaceID(at: point, tolerance: 26, minHeight: SnowWorld.minSnowToRoll),
              let drift = drifts[surfaceID],
              let rect = surfaces[surfaceID]?.rect
        else { return nil }

        let localX = max(0, min(rect.width, point.x - rect.x))
        let taken = drift.take(aroundX: localX, halfWidth: max(8, drift.columnSpacing), fraction: 0.5)
        let radius = max(SnowWorld.minSnowballRadius, min(SnowWorld.maxSnowballRadius, (taken / Float.pi).squareRoot()))
        var ball = Snowball(id: makeObjectID(), center: point, radius: radius, state: .rolling)
        ball.surfaceID = surfaceID
        ball.localX = localX
        ball.center = SIMD2(rect.x + localX, restY(rect: rect, drift: drift, localX: localX, radius: radius))
        snowballs.append(ball)
        return ball.id
    }

    /// Moves a rolling/held ball to the cursor. On a drift it rolls along the snow surface
    /// and grows with what it picks up; elsewhere it follows the cursor through the air.
    /// Returns false if the ball no longer exists or is not held (e.g. after `clearAll`).
    @discardableResult
    public func rollBall(_ id: Int, to point: SIMD2<Float>) -> Bool {
        guard let i = snowballIndex(id) else { return false }
        var ball = snowballs[i]
        guard ball.state == .rolling || ball.state == .held else { return false }
        guard point.x.isFinite, point.y.isFinite else { return true }

        var target: Int?
        if let current = ball.surfaceID, isRollable(point, on: current, radius: ball.radius, minHeight: 0) {
            target = current
        } else {
            target = rollableSurface(at: point, radius: ball.radius)
        }

        guard let surfaceID = target, let drift = drifts[surfaceID], let rect = surfaces[surfaceID]?.rect else {
            ball.center = point
            ball.state = .held
            ball.surfaceID = nil
            snowballs[i] = ball
            return true
        }

        let margin = min(ball.radius * 0.5, rect.width * 0.5)
        let localX = max(margin, min(rect.width - margin, point.x - rect.x))
        let newX = rect.x + localX
        let dx = newX - ball.center.x
        if ball.state == .rolling, ball.surfaceID == surfaceID, abs(dx) > 0.01, abs(dx) < 200 {
            let maxR = SnowWorld.maxSnowballRadius
            let room = Float.pi * (maxR * maxR - ball.radius * ball.radius)
            if room > 0.5 {
                let share = min(0.6, abs(dx) / (ball.radius * 3))
                let taken = drift.take(
                    aroundX: localX,
                    halfWidth: max(drift.columnSpacing, ball.radius * 0.9),
                    fraction: share,
                    limit: room
                )
                ball.radius = min(maxR, (ball.radius * ball.radius + taken / Float.pi).squareRoot())
            }
            ball.rotation += dx / ball.radius
        }
        ball.state = .rolling
        ball.surfaceID = surfaceID
        ball.localX = localX
        ball.center = SIMD2(newX, restY(rect: rect, drift: drift, localX: localX, radius: ball.radius))
        snowballs[i] = ball
        return true
    }

    /// Lets go of a rolling/held ball; it flies off with part of `velocity` (pt/s) and
    /// falls. Returns false if there is no such held ball.
    @discardableResult
    public func releaseBall(_ id: Int, velocity: SIMD2<Float>) -> Bool {
        guard let i = snowballIndex(id),
              snowballs[i].state == .rolling || snowballs[i].state == .held
        else { return false }
        var v = velocity.x.isFinite && velocity.y.isFinite ? velocity * 0.5 : .zero
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        if speed > SnowWorld.snowballMaxReleaseSpeed {
            v *= SnowWorld.snowballMaxReleaseSpeed / speed
        }
        snowballs[i].state = .falling
        snowballs[i].velocity = v
        snowballs[i].surfaceID = nil
        snowballs[i].ignoredSurfaceID = nil
        return true
    }

    /// Front-most surface whose snow bank is under `point` (within `tolerance` points of it)
    /// and not hidden behind a window in front. Nil when the point is not on snow.
    public func driftSurfaceID(at point: SIMD2<Float>, tolerance: Float = 8, minHeight: Float = 0.5) -> Int? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        for (k, entry) in entries.enumerated() {
            let r = entry.rect
            guard point.x >= r.x, point.x <= r.maxX else { continue }
            let h = entry.drift.height(atX: point.x - r.x)
            if h >= minHeight, h > 0,
               point.y >= r.y - h - tolerance, point.y <= r.y + tolerance,
               !isCovered(SIMD2(point.x, r.y - h * 0.5), byFirst: k) {
                return entry.id
            }
            // A window under the cursor hides everything behind it.
            if r.contains(point) { return nil }
        }
        return nil
    }

    // MARK: - Helpers

    func makeObjectID() -> Int {
        let id = nextObjectID
        nextObjectID += 1
        return id
    }

    func snowballIndex(_ id: Int) -> Int? {
        snowballs.firstIndex { $0.id == id }
    }

    func entryIndex(_ id: Int) -> Int? {
        entries.firstIndex { $0.id == id }
    }

    /// True if one of the first `count` (front-most) surfaces contains `p`.
    func isCovered(_ p: SIMD2<Float>, byFirst count: Int) -> Bool {
        var j = 0
        while j < count, j < entries.count {
            if entries[j].rect.contains(p) { return true }
            j += 1
        }
        return false
    }

    func restY(rect: Rect, drift: Drift, localX: Float, radius: Float) -> Float {
        rect.y - drift.height(atX: localX) * SnowWorld.snowballSink - radius
    }

    private func pickableBallIndex(near point: SIMD2<Float>) -> Int? {
        for i in snowballs.indices.reversed() {
            let b = snowballs[i]
            guard b.state == .resting, b.childID == nil else { continue }
            let d = b.center - point
            if (d.x * d.x + d.y * d.y).squareRoot() <= b.radius + 6 { return i }
        }
        return nil
    }

    private func detachFromParent(_ i: Int) {
        guard let parent = snowballs[i].parentID else { return }
        if let p = snowballIndex(parent) { snowballs[p].childID = nil }
        snowballs[i].parentID = nil
    }

    private func isRollable(_ point: SIMD2<Float>, on surfaceID: Int, radius: Float, minHeight: Float) -> Bool {
        guard let k = entryIndex(surfaceID) else { return false }
        let entry = entries[k]
        let r = entry.rect
        guard point.x >= r.x, point.x <= r.maxX else { return false }
        let h = entry.drift.height(atX: point.x - r.x)
        guard h >= minHeight else { return false }
        guard point.y >= r.y - h - radius * 2 - 30, point.y <= r.y + 30 else { return false }
        return !isCovered(SIMD2(point.x, r.y - max(h, 1) * 0.5), byFirst: k)
    }

    private func rollableSurface(at point: SIMD2<Float>, radius: Float) -> Int? {
        for entry in entries {
            let r = entry.rect
            guard point.x >= r.x, point.x <= r.maxX else { continue }
            if isRollable(point, on: entry.id, radius: radius, minHeight: 0.5) { return entry.id }
            if r.contains(point) { return nil }
        }
        return nil
    }

    /// Ids of the stack starting at `rootIndex`, bottom first.
    private func stackIDs(fromRoot rootIndex: Int) -> [Int] {
        var ids = [snowballs[rootIndex].id]
        var next = snowballs[rootIndex].childID
        while let id = next, ids.count < 8, let j = snowballIndex(id) {
            ids.append(id)
            next = snowballs[j].childID
        }
        return ids
    }

    /// Number of balls from `index` down to the bottom of its stack, inclusive.
    private func stackDepth(_ index: Int) -> Int {
        var depth = 1
        var parent = snowballs[index].parentID
        while let id = parent, depth < 8, let j = snowballIndex(id) {
            depth += 1
            parent = snowballs[j].parentID
        }
        return depth
    }

    // MARK: - Surface changes

    func snowObjectsSurfacesChanged(removed: Set<Int>, shaken: [Int: SIMD2<Float>]) {
        // A rolling ball whose drift vanished is just held by the cursor now.
        for i in snowballs.indices where snowballs[i].state == .rolling {
            if let id = snowballs[i].surfaceID, surfaces[id] == nil {
                snowballs[i].state = .held
                snowballs[i].surfaceID = nil
            }
        }

        let roots = snowballs.filter { $0.state == .resting && $0.parentID == nil }.map { $0.id }
        for rootID in roots {
            guard let i = snowballIndex(rootID), let surfaceID = snowballs[i].surfaceID else { continue }
            if let velocity = knockVelocity(surfaceID: surfaceID, localX: snowballs[i].localX, removed: removed, shaken: shaken) {
                dropStack(rootIndex: i, velocity: velocity, ignoring: removed.contains(surfaceID) ? nil : surfaceID)
            }
        }

        var k = snowmen.count - 1
        while k >= 0 {
            let man = snowmen[k]
            if let velocity = knockVelocity(surfaceID: man.surfaceID, localX: man.localX, removed: removed, shaken: shaken) {
                topple(snowmanAt: k, velocity: velocity, ignoring: removed.contains(man.surfaceID) ? nil : man.surfaceID)
            }
            k -= 1
        }
    }

    /// Velocity to knock an object off its surface with, or nil if it stays.
    private func knockVelocity(surfaceID: Int, localX: Float, removed: Set<Int>, shaken: [Int: SIMD2<Float>]) -> SIMD2<Float>? {
        if removed.contains(surfaceID) || surfaces[surfaceID] == nil {
            return SIMD2(0, -20)
        }
        if let shift = shaken[surfaceID] {
            // The tracker polls about ten times a second.
            var v = shift * 10
            let speed = (v.x * v.x + v.y * v.y).squareRoot()
            if speed > 600 { v *= 600 / speed }
            return SIMD2(v.x * 0.6, min(v.y * 0.4, 0) - 80)
        }
        if let rect = surfaces[surfaceID]?.rect, localX > rect.width {
            return SIMD2(30, 0)
        }
        return nil
    }

    private func dropStack(rootIndex: Int, velocity: SIMD2<Float>, ignoring surfaceID: Int?) {
        for id in stackIDs(fromRoot: rootIndex) {
            guard let j = snowballIndex(id) else { continue }
            snowballs[j].state = .falling
            snowballs[j].parentID = nil
            snowballs[j].childID = nil
            snowballs[j].surfaceID = nil
            snowballs[j].ignoredSurfaceID = surfaceID
            snowballs[j].velocity = velocity + SIMD2(rng.signedUnit() * 40, -rng.unit() * 40)
        }
    }

    /// Breaks a snowman into its three balls, which fall.
    private func topple(snowmanAt k: Int, velocity: SIMD2<Float>, ignoring surfaceID: Int?) {
        let man = snowmen.remove(at: k)
        for (center, radius) in zip(man.centers, man.radii) {
            var ball = Snowball(id: makeObjectID(), center: center, radius: radius, state: .falling)
            ball.ignoredSurfaceID = surfaceID
            ball.velocity = velocity + SIMD2(rng.signedUnit() * 60, -rng.unit() * 50)
            snowballs.append(ball)
        }
    }

    // MARK: - Simulation

    func stepSnowObjects(dt: Float) {
        guard !snowballs.isEmpty || !snowmen.isEmpty else { return }
        followSurfaces()

        let falling = snowballs.filter { $0.state == .falling }.map { $0.id }
        for id in falling {
            guard let i = snowballIndex(id) else { continue }
            var b = snowballs[i]
            let previousY = b.center.y
            b.velocity.y = min(SnowWorld.snowballMaxFallSpeed, b.velocity.y + SnowWorld.snowballGravity * dt)
            b.velocity.x *= exp(-0.8 * dt)
            b.center += b.velocity * dt
            b.rotation += b.velocity.x * dt / max(1, b.radius)
            snowballs[i] = b

            if b.velocity.y > 0 {
                if landOnStack(i, previousY: previousY) { continue }
                if landOnSurface(i, previousY: previousY) { continue }
            }
            if b.center.y + b.radius >= bounds.maxY {
                shatter(ballAt: i)
            } else if b.center.x < bounds.x - 200 || b.center.x > bounds.maxX + 200 {
                snowballs.remove(at: i)
            }
        }
    }

    /// Rolling balls, resting stacks and snowmen sit on their (possibly moved) surfaces.
    private func followSurfaces() {
        for i in snowballs.indices {
            let b = snowballs[i]
            guard b.state == .rolling || (b.state == .resting && b.parentID == nil),
                  let id = b.surfaceID, let rect = surfaces[id]?.rect, let drift = drifts[id]
            else { continue }
            let localX = max(0, min(rect.width, b.localX))
            snowballs[i].localX = localX
            snowballs[i].center = SIMD2(rect.x + localX, restY(rect: rect, drift: drift, localX: localX, radius: b.radius))
        }
        for i in snowballs.indices where snowballs[i].state == .resting && snowballs[i].parentID == nil {
            var below = snowballs[i]
            var next = below.childID
            var guardCount = 0
            while let id = next, let j = snowballIndex(id), guardCount < 8 {
                let r = snowballs[j].radius
                snowballs[j].center = SIMD2(below.center.x, below.center.y - (below.radius + r) * Snowball.stackOverlap)
                snowballs[j].surfaceID = below.surfaceID
                snowballs[j].localX = below.localX
                below = snowballs[j]
                next = below.childID
                guardCount += 1
            }
        }
        for k in snowmen.indices {
            let man = snowmen[k]
            guard let rect = surfaces[man.surfaceID]?.rect, let drift = drifts[man.surfaceID] else { continue }
            let localX = max(0, min(rect.width, man.localX))
            snowmen[k].localX = localX
            snowmen[k].position = SIMD2(
                rect.x + localX,
                restY(rect: rect, drift: drift, localX: localX, radius: man.bottomRadius)
            )
        }
    }

    /// Lands a falling ball on the top ball of a resting stack; three make a snowman.
    private func landOnStack(_ i: Int, previousY: Float) -> Bool {
        let b = snowballs[i]
        for j in snowballs.indices where j != i {
            let top = snowballs[j]
            guard top.state == .resting, top.childID == nil,
                  let surfaceID = top.surfaceID, surfaceID != b.ignoredSurfaceID,
                  abs(b.center.x - top.center.x) <= top.radius * 0.9
            else { continue }
            let target = top.center.y - (top.radius + b.radius) * Snowball.stackOverlap
            guard previousY <= target + 2, b.center.y >= target else { continue }
            if let k = entryIndex(surfaceID), isCovered(top.center, byFirst: k) { continue }

            snowballs[i].state = .resting
            snowballs[i].parentID = top.id
            snowballs[i].surfaceID = surfaceID
            snowballs[i].localX = top.localX
            snowballs[i].velocity = .zero
            snowballs[i].ignoredSurfaceID = nil
            snowballs[i].center = SIMD2(top.center.x, target)
            snowballs[j].childID = b.id
            if stackDepth(i) >= 3 {
                makeSnowman(topID: b.id)
            }
            return true
        }
        return false
    }

    /// Lands a falling ball on the front-most drift it crosses.
    private func landOnSurface(_ i: Int, previousY: Float) -> Bool {
        let b = snowballs[i]
        for entry in entries {
            let r = entry.rect
            guard b.center.x >= r.x, b.center.x <= r.maxX else { continue }
            if entry.id != b.ignoredSurfaceID {
                let localX = b.center.x - r.x
                let rest = restY(rect: r, drift: entry.drift, localX: localX, radius: b.radius)
                if previousY <= rest + 4, b.center.y >= rest {
                    snowballs[i].state = .resting
                    snowballs[i].surfaceID = entry.id
                    snowballs[i].localX = localX
                    snowballs[i].parentID = nil
                    snowballs[i].velocity = .zero
                    snowballs[i].ignoredSurfaceID = nil
                    snowballs[i].center.y = rest
                    return true
                }
            }
            // Behind this window: surfaces further back are out of reach.
            if b.center.y > r.y, b.center.y < r.maxY { return false }
        }
        return false
    }

    private func makeSnowman(topID: Int) {
        guard let top = snowballIndex(topID),
              let midID = snowballs[top].parentID, let mid = snowballIndex(midID),
              let rootID = snowballs[mid].parentID, let root = snowballIndex(rootID),
              let surfaceID = snowballs[root].surfaceID
        else { return }
        let bottom = snowballs[root]
        let man = Snowman(
            id: makeObjectID(),
            surfaceID: surfaceID,
            localX: bottom.localX,
            radii: (bottom.radius, snowballs[mid].radius, snowballs[top].radius),
            facing: rng.unit() < 0.5 ? -1 : 1,
            position: bottom.center
        )
        let ids: Set<Int> = [topID, midID, rootID]
        snowballs.removeAll { ids.contains($0.id) }
        snowmen.append(man)
        while snowmen.count > SnowWorld.maxSnowmen {
            let old = snowmen.removeFirst()
            for (center, radius) in zip(old.centers, old.radii) {
                burst(at: center, radius: radius, ignoring: old.surfaceID)
            }
        }
    }

    /// A falling ball hit the bottom of the bounds: it bursts into debris.
    private func shatter(ballAt i: Int) {
        let b = snowballs.remove(at: i)
        let y = min(b.center.y, bounds.maxY - b.radius)
        burst(at: SIMD2(b.center.x, y), radius: b.radius, ignoring: nil)
    }

    func burst(at center: SIMD2<Float>, radius: Float, ignoring surfaceID: Int?) {
        let amount = Float.pi * radius * radius
        let spread = radius * 0.7
        emitPieces(amount: amount, maxPieces: 30, ignoring: surfaceID) { rng in
            let offset = SIMD2<Float>(rng.signedUnit() * spread, rng.signedUnit() * spread)
            let velocity = SIMD2<Float>(rng.signedUnit() * 140, -rng.float(in: 40...220))
            return (center + offset, velocity)
        }
    }
}
