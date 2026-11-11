import XCTest
@testable import SnowCore

final class SnowballTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, width: 800, height: 600)
    private let window = Surface(id: 1, rect: Rect(x: 100, y: 300, width: 400, height: 200))

    private func run(_ world: SnowWorld, steps: Int, dt: Float = 1.0 / 60.0) {
        for _ in 0..<steps { world.step(dt: dt) }
    }

    /// No snowfall; an even ~10pt layer on `window`.
    private func snowyWorld() -> SnowWorld {
        let world = SnowWorld(bounds: screen, seed: 7)
        world.particleBudgetScale = 0
        world.setSurfaces([window])
        let drift = world.drifts[window.id]!
        for x in stride(from: Float(0), through: window.rect.width, by: 2) {
            drift.deposit(atX: x, amount: 20)
        }
        return world
    }

    private func ball(_ world: SnowWorld, _ id: Int) -> Snowball? {
        world.snowballs.first { $0.id == id }
    }

    /// Rolls a ball from `x` a little to the right, then releases it in place.
    @discardableResult
    private func rollAndDrop(_ world: SnowWorld, from x: Float, to point: SIMD2<Float>? = nil) -> Int {
        let id = world.beginRoll(at: SIMD2(x, 290))!
        for step in 1...20 {
            XCTAssertTrue(world.rollBall(id, to: SIMD2(x + Float(step) * 2, 290)))
        }
        if let point {
            XCTAssertTrue(world.rollBall(id, to: point))
            XCTAssertEqual(ball(world, id)?.state, .held)
        }
        XCTAssertTrue(world.releaseBall(id, velocity: .zero))
        return id
    }

    private func runUntilSettled(_ world: SnowWorld, maxSteps: Int = 240) {
        for _ in 0..<maxSteps {
            world.step(dt: 1.0 / 60.0)
            if !world.snowballs.contains(where: { $0.state == .falling }) { return }
        }
    }

    func testBeginRollNeedsSnow() {
        let world = snowyWorld()
        XCTAssertNil(world.beginRoll(at: SIMD2(50, 100)), "empty air")
        XCTAssertNil(world.beginRoll(at: SIMD2(300, 400)), "inside the window body")

        let bare = SnowWorld(bounds: screen, seed: 1)
        bare.particleBudgetScale = 0
        bare.setSurfaces([window])
        XCTAssertNil(bare.beginRoll(at: SIMD2(300, 298)), "drift without snow")
        XCTAssertTrue(bare.snowballs.isEmpty)
    }

    func testRollingConservesSnowAndGrowsBall() {
        let world = snowyWorld()
        let before = world.totalSnow
        let id = world.beginRoll(at: SIMD2(200, 290))!
        let start = ball(world, id)!
        XCTAssertEqual(start.state, .rolling)
        XCTAssertEqual(start.surfaceID, window.id)
        XCTAssertGreaterThanOrEqual(start.radius, SnowWorld.minSnowballRadius)
        XCTAssertEqual(world.totalSnow + start.area, before, accuracy: 1)

        for step in 1...60 {
            world.rollBall(id, to: SIMD2(200 + Float(step) * 3, 290))
        }
        let rolled = ball(world, id)!
        XCTAssertGreaterThan(rolled.radius, start.radius)
        XCTAssertEqual(world.totalSnow + rolled.area, before, accuracy: 1)
        XCTAssertLessThan(rolled.center.y, window.rect.y, "ball sits on top of the drift")
    }

    func testRadiusIsCapped() {
        let world = snowyWorld()
        let drift = world.drifts[window.id]!
        for x in stride(from: Float(0), through: window.rect.width, by: 2) {
            drift.deposit(atX: x, amount: 200)
        }
        let before = world.totalSnow
        let id = world.beginRoll(at: SIMD2(120, 270))!
        for pass in 0..<6 {
            for step in 0...100 {
                let t = Float(pass % 2 == 0 ? step : 100 - step) / 100
                world.rollBall(id, to: SIMD2(110 + t * 380, 270))
            }
        }
        let b = ball(world, id)!
        XCTAssertLessThanOrEqual(b.radius, SnowWorld.maxSnowballRadius + 1e-3)
        XCTAssertEqual(b.radius, SnowWorld.maxSnowballRadius, accuracy: 0.5)
        XCTAssertEqual(world.totalSnow + b.area, before, accuracy: 2)
    }

    func testReleasedBallLandsAndFollowsSurface() {
        let world = snowyWorld()
        let id = rollAndDrop(world, from: 200, to: SIMD2(260, 150))
        XCTAssertEqual(ball(world, id)?.state, .falling)
        runUntilSettled(world)
        let resting = ball(world, id)!
        XCTAssertEqual(resting.state, .resting)
        XCTAssertEqual(resting.surfaceID, window.id)
        XCTAssertEqual(resting.center.x, 260, accuracy: 1)
        XCTAssertLessThan(resting.center.y, window.rect.y)

        var moved = window
        moved.rect.x += 10
        moved.rect.y += 6
        world.setSurfaces([moved])
        world.step(dt: 1.0 / 60.0)
        let followed = ball(world, id)!
        XCTAssertEqual(followed.state, .resting)
        XCTAssertEqual(followed.center.x, resting.center.x + 10, accuracy: 0.01)
        XCTAssertEqual(followed.center.y, resting.center.y + 6, accuracy: 0.5)
    }

    func testThreeStackedBallsMakeSnowman() {
        let world = snowyWorld()
        rollAndDrop(world, from: 150)
        runUntilSettled(world)
        let bottom = world.snowballs[0]
        XCTAssertEqual(bottom.state, .resting)

        rollAndDrop(world, from: 300, to: SIMD2(bottom.center.x, bottom.center.y - 90))
        runUntilSettled(world)
        XCTAssertEqual(world.snowballs.count, 2)
        let middle = world.snowballs.first { $0.parentID == bottom.id }
        XCTAssertNotNil(middle, "second ball sits on the first")
        XCTAssertTrue(world.snowmen.isEmpty)

        rollAndDrop(world, from: 400, to: SIMD2(bottom.center.x, bottom.center.y - 140))
        runUntilSettled(world)
        XCTAssertTrue(world.snowballs.isEmpty)
        XCTAssertEqual(world.snowmen.count, 1)
        let man = world.snowmen[0]
        XCTAssertEqual(man.surfaceID, window.id)
        XCTAssertEqual(man.position.x, bottom.center.x, accuracy: 0.5)
        XCTAssertLessThan(man.headCenter.y, man.middleCenter.y)
        XCTAssertLessThan(man.middleCenter.y, man.bottomCenter.y)
        XCTAssertEqual(abs(man.facing), 1)

        // Gentle moves carry it along.
        var moved = window
        moved.rect.x -= 15
        world.setSurfaces([moved])
        world.step(dt: 1.0 / 60.0)
        XCTAssertEqual(world.snowmen.count, 1)
        XCTAssertEqual(world.snowmen[0].position.x, man.position.x - 15, accuracy: 0.01)
    }

    private func worldWithSnowman() -> SnowWorld {
        let world = snowyWorld()
        rollAndDrop(world, from: 150)
        runUntilSettled(world)
        let bottom = world.snowballs[0]
        rollAndDrop(world, from: 300, to: SIMD2(bottom.center.x, bottom.center.y - 90))
        runUntilSettled(world)
        rollAndDrop(world, from: 400, to: SIMD2(bottom.center.x, bottom.center.y - 140))
        runUntilSettled(world)
        XCTAssertEqual(world.snowmen.count, 1)
        return world
    }

    func testShakeTopplesSnowmanAndBallsBurstAtBottom() {
        let world = worldWithSnowman()
        world.drifts[window.id]!.clear()

        var moved = window
        moved.rect.x += 150
        world.setSurfaces([moved])
        XCTAssertTrue(world.snowmen.isEmpty)
        XCTAssertEqual(world.snowballs.count, 3)
        XCTAssertTrue(world.snowballs.allSatisfy { $0.state == .falling })

        var burst = false
        for _ in 0..<300 {
            let balls = world.snowballs.count
            let flakes = world.flakes.count
            world.step(dt: 1.0 / 60.0)
            if world.snowballs.count < balls, world.flakes.count > flakes { burst = true }
            if world.snowballs.isEmpty { break }
        }
        XCTAssertTrue(world.snowballs.isEmpty)
        XCTAssertTrue(burst, "balls break into debris at the bottom")
    }

    func testRemovedSurfaceDropsRestingBall() {
        let world = snowyWorld()
        let id = rollAndDrop(world, from: 200)
        runUntilSettled(world)
        XCTAssertEqual(ball(world, id)?.state, .resting)
        world.setSurfaces([])
        XCTAssertEqual(ball(world, id)?.state, .falling)
    }

    func testClearAllRemovesBallsAndSnowmen() {
        let world = worldWithSnowman()
        let held = world.beginRoll(at: SIMD2(450, 290))
        XCTAssertNotNil(held)
        world.clearAll()
        XCTAssertTrue(world.snowballs.isEmpty)
        XCTAssertTrue(world.snowmen.isEmpty)
        XCTAssertFalse(world.rollBall(held!, to: SIMD2(460, 290)))
        XCTAssertFalse(world.releaseBall(held!, velocity: .zero))
    }

    func testSweepLeavesSnowballsAlone() {
        let world = snowyWorld()
        let id = rollAndDrop(world, from: 200)
        runUntilSettled(world)
        let before = ball(world, id)!
        world.sweep(at: before.center, radius: 18, direction: SIMD2(1, 0))
        XCTAssertEqual(ball(world, id)?.radius, before.radius)
        XCTAssertEqual(ball(world, id)?.state, .resting)
    }

    func testDirectionalSweepKicksSnowThatWay() {
        let world = snowyWorld()
        world.sweep(at: SIMD2(300, 296), radius: 15, direction: SIMD2(400, 0))
        XCTAssertFalse(world.flakes.isEmpty)
        let meanVX = world.flakes.reduce(Float(0)) { $0 + $1.velocity.x } / Float(world.flakes.count)
        XCTAssertGreaterThan(meanVX, 50)
        XCTAssertTrue(world.flakes.allSatisfy { $0.isDebris })
    }

    func testDriftTakeRespectsLimit() {
        let drift = Drift(width: 100)
        for x in stride(from: Float(0), through: 100, by: 2) { drift.deposit(atX: x, amount: 20) }
        let before = drift.totalSnow
        let taken = drift.take(aroundX: 50, halfWidth: 20, fraction: 1, limit: 30)
        XCTAssertEqual(taken, 30, accuracy: 1e-3)
        XCTAssertEqual(drift.totalSnow, before - 30, accuracy: 1e-3)
    }
}
