import XCTest
@testable import SnowCore

final class SnowWorldTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, width: 800, height: 600)
    private let window = Surface(id: 1, rect: Rect(x: 100, y: 300, width: 400, height: 200))

    private func run(_ world: SnowWorld, steps: Int, dt: Float = 1.0 / 60.0) {
        for _ in 0..<steps { world.step(dt: dt) }
    }

    /// World with no snowfall and some snow already lying on `window`.
    private func snowyWorld() -> SnowWorld {
        let world = SnowWorld(bounds: screen, seed: 5)
        world.particleBudgetScale = 0
        world.setSurfaces([window])
        let drift = world.drifts[window.id]!
        for x in stride(from: Float(0), through: window.rect.width, by: 2) {
            drift.deposit(atX: x, amount: 20)
        }
        XCTAssertTrue(world.flakes.isEmpty)
        return world
    }

    private func meanY(_ flakes: [Flake]) -> Float {
        flakes.reduce(Float(0)) { $0 + $1.position.y } / Float(max(1, flakes.count))
    }

    func testSameSeedIsDeterministic() {
        let a = SnowWorld(bounds: screen, seed: 11)
        let b = SnowWorld(bounds: screen, seed: 11)
        a.setSurfaces([window])
        b.setSurfaces([window])
        run(a, steps: 200)
        run(b, steps: 200)
        XCTAssertFalse(a.flakes.isEmpty)
        XCTAssertEqual(a.flakes, b.flakes)
        XCTAssertEqual(a.totalSnow, b.totalSnow)
    }

    func testFlakesLandOnSurface() {
        let world = SnowWorld(bounds: screen, seed: 1, preset: .steady)
        world.setSurfaces([window])
        XCTAssertEqual(world.totalSnow, 0)
        run(world, steps: 900)
        let drift = world.drifts[window.id]!
        XCTAssertGreaterThan(world.totalSnow, 0)
        XCTAssertGreaterThan(drift.totalSnow, 0)
        XCTAssertGreaterThan(drift.height(atX: 200), 0)

        let later = world.totalSnow
        run(world, steps: 300)
        XCTAssertGreaterThan(world.totalSnow, later)
    }

    func testRemovingSurfaceCrumblesIntoFallingFlakes() {
        let world = snowyWorld()
        XCTAssertGreaterThan(world.totalSnow, 0)

        world.setSurfaces([])
        XCTAssertNil(world.drifts[window.id])
        XCTAssertNil(world.surfaces[window.id])
        XCTAssertTrue(world.surfaceOrder.isEmpty)
        XCTAssertEqual(world.totalSnow, 0)
        XCTAssertFalse(world.flakes.isEmpty)
        XCTAssertTrue(world.flakes.allSatisfy { $0.isDebris })

        let startY = meanY(world.flakes)
        run(world, steps: 30)
        XCTAssertFalse(world.flakes.isEmpty)
        XCTAssertGreaterThan(meanY(world.flakes), startY)
    }

    func testMovingSurfaceKeepsDriftAttached() {
        let world = snowyWorld()
        let drift = world.drifts[window.id]!
        let before = world.totalSnow
        let heightBefore = drift.height(atX: 200)

        var moved = window
        moved.rect.x += 10
        moved.rect.y += 5
        world.setSurfaces([moved])
        XCTAssertTrue(world.drifts[window.id] === drift)
        XCTAssertEqual(world.surfaces[window.id], moved)
        XCTAssertEqual(world.totalSnow, before, accuracy: 1e-3)
        XCTAssertEqual(drift.height(atX: 200), heightBefore, accuracy: 1e-4)
        XCTAssertTrue(world.flakes.isEmpty)

        // A fast jump shakes part of the snow off, but the drift stays.
        moved.rect.x += 300
        world.setSurfaces([moved])
        XCTAssertTrue(world.drifts[window.id] === drift)
        XCTAssertLessThan(world.totalSnow, before)
        XCTAssertGreaterThan(world.totalSnow, 0)
        XCTAssertFalse(world.flakes.isEmpty)
        XCTAssertTrue(world.flakes.allSatisfy { $0.ignoredSurfaceID == window.id })
    }

    func testShrinkingSurfaceDropsSnowPastEdge() {
        let world = snowyWorld()
        let before = world.totalSnow
        var resized = window
        resized.rect.width = 200
        world.setSurfaces([resized])
        XCTAssertEqual(world.drifts[window.id]!.width, 200)
        XCTAssertLessThan(world.totalSnow, before)
        XCTAssertFalse(world.flakes.isEmpty)
    }

    func testWindShiftsFlakesSideways() {
        func meanVelocityX(wind: Float) -> Float {
            let world = SnowWorld(bounds: Rect(x: 0, y: 0, width: 1000, height: 800), seed: 3)
            world.wind = Wind(x: wind)
            run(world, steps: 300)
            XCTAssertFalse(world.flakes.isEmpty)
            return world.flakes.reduce(Float(0)) { $0 + $1.velocity.x } / Float(world.flakes.count)
        }
        let right = meanVelocityX(wind: 1)
        let calm = meanVelocityX(wind: 0)
        let left = meanVelocityX(wind: -1)
        XCTAssertGreaterThan(right, 60)
        XCTAssertLessThan(left, -60)
        XCTAssertLessThan(abs(calm), 20)
    }

    func testUpwardWindSlowsFall() {
        func meanVelocityY(windY: Float) -> Float {
            let world = SnowWorld(bounds: screen, seed: 8)
            world.wind = Wind(x: 0, y: windY)
            run(world, steps: 120)
            return world.flakes.reduce(Float(0)) { $0 + $1.velocity.y } / Float(max(1, world.flakes.count))
        }
        XCTAssertLessThan(meanVelocityY(windY: -1), meanVelocityY(windY: 0))
        XCTAssertGreaterThan(meanVelocityY(windY: -1), 0)
    }

    func testPausedWorldDoesNotChange() {
        let world = SnowWorld(bounds: screen, seed: 2)
        world.setSurfaces([window])
        run(world, steps: 600)
        XCTAssertFalse(world.flakes.isEmpty)

        world.isPaused = true
        let flakes = world.flakes
        let snow = world.totalSnow
        let time = world.time
        run(world, steps: 200)
        XCTAssertEqual(world.flakes, flakes)
        XCTAssertEqual(world.totalSnow, snow)
        XCTAssertEqual(world.time, time)

        world.isPaused = false
        world.step(dt: 1.0 / 60.0)
        XCTAssertNotEqual(world.flakes, flakes)
    }

    func testPresetCapsRespected() {
        let bounds = Rect(x: 0, y: 0, width: 1440, height: 900)
        for preset in SnowfallPreset.allCases {
            let world = SnowWorld(bounds: bounds, seed: 9, preset: preset)
            let cap = world.flakeCap
            XCTAssertEqual(cap, preset.baseFlakeCap)
            var peak = 0
            for _ in 0..<1200 {
                world.step(dt: 1.0 / 30.0)
                peak = max(peak, world.flakes.count)
            }
            XCTAssertLessThanOrEqual(peak, cap, "\(preset)")
            XCTAssertGreaterThan(peak, cap * 8 / 10, "\(preset) never got close to its cap")
        }

        let lowPower = SnowWorld(bounds: bounds, seed: 9, preset: .blizzard)
        lowPower.particleBudgetScale = 0.5
        XCTAssertEqual(lowPower.flakeCap, 750)
        var peak = 0
        for _ in 0..<600 {
            lowPower.step(dt: 1.0 / 30.0)
            peak = max(peak, lowPower.flakes.count)
        }
        XCTAssertLessThanOrEqual(peak, 750)
    }

    func testBudgetScaleIsClamped() {
        let world = SnowWorld(bounds: screen, seed: 1)
        world.particleBudgetScale = 3
        XCTAssertEqual(world.particleBudgetScale, 1)
        world.particleBudgetScale = -1
        XCTAssertEqual(world.particleBudgetScale, 0)
    }

    func testSweepRemovesSnowAndKicksFlakes() {
        let world = snowyWorld()
        let before = world.totalSnow
        world.sweep(at: SIMD2(300, 296), radius: 15)
        XCTAssertLessThan(world.totalSnow, before)
        XCTAssertEqual(world.drifts[window.id]!.height(atX: 200), 0, accuracy: 1e-4)
        XCTAssertFalse(world.flakes.isEmpty)
        XCTAssertTrue(world.flakes.allSatisfy { $0.isDebris && abs($0.velocity.x) > 0 && $0.velocity.y < 0 })

        // Far from any surface nothing happens.
        let count = world.flakes.count
        let snow = world.totalSnow
        world.sweep(at: SIMD2(700, 50), radius: 15)
        XCTAssertEqual(world.flakes.count, count)
        XCTAssertEqual(world.totalSnow, snow)
    }

    func testClearAllRemovesEverything() {
        let world = SnowWorld(bounds: screen, seed: 4)
        world.setSurfaces([window])
        run(world, steps: 900)
        XCTAssertGreaterThan(world.totalSnow, 0)
        world.clearAll()
        XCTAssertEqual(world.totalSnow, 0)
        XCTAssertTrue(world.flakes.isEmpty)
        XCTAssertNotNil(world.drifts[window.id])
    }

    func testFrontSurfaceIsHitFirst() {
        let world = SnowWorld(bounds: screen, seed: 6)
        let front = Surface(id: 10, rect: Rect(x: 200, y: 200, width: 400, height: 300))
        let back = Surface(id: 20, rect: Rect(x: 0, y: 350, width: 800, height: 200))
        world.setSurfaces([front, back])
        XCTAssertEqual(world.surfaceOrder, [10, 20])
        run(world, steps: 900)
        let backDrift = world.drifts[20]!
        XCTAssertGreaterThan(world.drifts[10]!.totalSnow, 0)
        XCTAssertGreaterThan(backDrift.height(atX: 100), 0)
        // The part of the back window covered by the front one gets nothing.
        XCTAssertEqual(backDrift.height(atX: 400), 0)
    }

    /// Snow sliding off a full drift must not fall as a steady stream right at the window
    /// sides: from a distance that reads as a dotted line running down each edge.
    func testNoFlakeStreamsAlongWindowSides() {
        let world = SnowWorld(bounds: screen, seed: 9, preset: .steady)
        world.depositFactor = 30
        let side = Surface(id: 3, rect: Rect(x: 300, y: 150, width: 200, height: 350))
        world.setSurfaces([side])
        let r = side.rect
        // Let the drift fill up so it sheds snow off both ends all the time.
        run(world, steps: 60 * 60)
        XCTAssertGreaterThan(world.drifts[side.id]!.peakHeight, 20)

        let strip: Float = 6
        var nearEdge = 0
        var beside = 0
        for _ in 0..<(60 * 60 / 5) {
            run(world, steps: 5)
            for f in world.flakes where f.position.y > r.y + 10 && f.position.y < r.maxY {
                let x = f.position.x
                if abs(x - r.x) < strip || abs(x - r.maxX) < strip {
                    nearEdge += 1
                } else if (x > r.x - 110 && x < r.x - 20) || (x > r.maxX + 20 && x < r.maxX + 110) {
                    beside += 1
                }
            }
        }
        XCTAssertGreaterThan(beside, 0)
        let edgeDensity = Float(nearEdge) / (4 * strip)
        let besideDensity = Float(beside) / 180
        XCTAssertLessThanOrEqual(edgeDensity, 3 * besideDensity,
                                 "flakes crowd the window sides: \(nearEdge) near edges vs \(beside) beside")
    }
}
