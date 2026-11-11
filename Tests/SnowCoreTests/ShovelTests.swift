import XCTest
@testable import SnowCore

final class ShovelTests: XCTestCase {
    private let screen = Rect(x: 0, y: 0, width: 800, height: 600)
    private let left = Surface(id: 1, rect: Rect(x: 50, y: 300, width: 300, height: 200))
    private let right = Surface(id: 2, rect: Rect(x: 450, y: 250, width: 300, height: 200))

    /// No snowfall. `left` carries a band of snow well away from its edges (so nothing
    /// spills off and totals stay exact); `right` is bare.
    private func world() -> SnowWorld {
        let world = SnowWorld(bounds: screen, seed: 3)
        world.particleBudgetScale = 0
        world.setSurfaces([left, right])
        let drift = world.drifts[left.id]!
        for x in stride(from: Float(80), through: 220, by: 2) {
            drift.deposit(atX: x, amount: 24)
        }
        drift.settle(passes: 200)
        return world
    }

    func testScoopMovesSnowFromDriftToShovel() {
        let world = world()
        let drift = world.drifts[left.id]!
        let before = drift.totalSnow
        let x = left.rect.x + 150
        let top = left.rect.y - drift.height(atX: 150)
        let taken = world.scoop(at: SIMD2(x, top + 2))
        XCTAssertGreaterThan(taken, 0)
        XCTAssertEqual(world.shovelLoad, taken, accuracy: 1e-3)
        XCTAssertEqual(drift.totalSnow, before - taken, accuracy: 1e-2)
        XCTAssertTrue(world.flakes.isEmpty, "scooping makes no debris")

        XCTAssertEqual(world.scoop(at: SIMD2(20, 100)), 0, "nothing to scoop in the air")
    }

    func testShovelLoadIsCapped() {
        let world = world()
        let drift = world.drifts[left.id]!
        for x in stride(from: Float(0), through: left.rect.width, by: 2) {
            drift.deposit(atX: x, amount: 400)
        }
        let before = drift.totalSnow
        for _ in 0..<50 {
            for x in stride(from: Float(60), through: 340, by: 10) {
                world.scoop(at: SIMD2(x, left.rect.y - 4), depth: 20)
            }
        }
        XCTAssertEqual(world.shovelLoad, SnowWorld.shovelCapacity, accuracy: 1e-2)
        XCTAssertEqual(drift.totalSnow, before - world.shovelLoad, accuracy: 0.5)
        XCTAssertEqual(world.scoop(at: SIMD2(200, left.rect.y - 4)), 0)
    }

    func testDumpBuildsPileOnAnotherSurface() {
        let world = world()
        let source = world.drifts[left.id]!
        for x in stride(from: Float(100), through: 200, by: 5) {
            world.scoop(at: SIMD2(left.rect.x + x, left.rect.y - 2), depth: 6)
        }
        let load = world.shovelLoad
        XCTAssertGreaterThan(load, 300)
        let total = world.totalSnow + load

        let id = world.dump(at: SIMD2(600, 150), velocity: .zero)
        XCTAssertNotNil(id)
        XCTAssertEqual(world.shovelLoad, 0)
        XCTAssertEqual(world.clumps.count, 1)
        XCTAssertEqual(world.clumps[0].amount, load)

        for _ in 0..<240 {
            world.step(dt: 1.0 / 60.0)
            if world.clumps.isEmpty { break }
        }
        XCTAssertTrue(world.clumps.isEmpty)
        let target = world.drifts[right.id]!
        XCTAssertEqual(target.totalSnow, load, accuracy: 0.5, "dumped snow equals scooped snow")
        XCTAssertEqual(world.totalSnow, total, accuracy: 0.5)
        XCTAssertTrue(world.flakes.isEmpty)
        XCTAssertGreaterThan(source.totalSnow, 0)

        let peak = target.height(atX: 150)
        XCTAssertGreaterThan(peak, 10, "a tall local heap")
        XCTAssertGreaterThan(peak, target.height(atX: 60) + 5)
        XCTAssertGreaterThan(peak, target.height(atX: 240) + 5)
    }

    func testDumpOnTheSameBankLandsThere() {
        let world = world()
        let drift = world.drifts[left.id]!
        world.scoop(at: SIMD2(left.rect.x + 150, left.rect.y - 2), depth: 8)
        let total = world.totalSnow + world.shovelLoad
        // The cursor is inside the bank; the clump must still land on it.
        world.dump(at: SIMD2(left.rect.x + 150, left.rect.y - 1), velocity: .zero)
        for _ in 0..<120 {
            world.step(dt: 1.0 / 60.0)
            if world.clumps.isEmpty { break }
        }
        XCTAssertTrue(world.clumps.isEmpty)
        XCTAssertEqual(drift.totalSnow, total, accuracy: 0.5)
    }

    func testDumpOffScreenBurstsIntoDebris() {
        let world = world()
        world.scoop(at: SIMD2(left.rect.x + 150, left.rect.y - 2))
        XCTAssertGreaterThan(world.shovelLoad, 0)
        let before = world.totalSnow
        world.dump(at: SIMD2(400, 100), velocity: .zero)
        var sawDebris = false
        for _ in 0..<240 {
            world.step(dt: 1.0 / 60.0)
            if world.flakes.contains(where: { $0.isDebris }) { sawDebris = true }
            if world.clumps.isEmpty { break }
        }
        XCTAssertTrue(world.clumps.isEmpty)
        XCTAssertTrue(sawDebris)
        XCTAssertEqual(world.totalSnow, before, accuracy: 1e-3, "no drift got the snow")
    }

    func testDumpWithEmptyShovelDoesNothing() {
        let world = world()
        XCTAssertNil(world.dump(at: SIMD2(200, 200), velocity: SIMD2(100, 0)))
        XCTAssertTrue(world.clumps.isEmpty)
    }

    func testClearAllEmptiesShovelAndClumps() {
        let world = world()
        world.scoop(at: SIMD2(left.rect.x + 150, left.rect.y - 2))
        world.dump(at: SIMD2(400, 100), velocity: .zero)
        world.scoop(at: SIMD2(left.rect.x + 120, left.rect.y - 2))
        world.clearAll()
        XCTAssertEqual(world.shovelLoad, 0)
        XCTAssertTrue(world.clumps.isEmpty)
        XCTAssertEqual(world.totalSnow, 0)
    }

    func testTransferShovelLoad() {
        let a = world()
        let b = SnowWorld(bounds: screen, seed: 4)
        a.scoop(at: SIMD2(left.rect.x + 150, left.rect.y - 2))
        let load = a.shovelLoad
        a.transferShovelLoad(to: b)
        XCTAssertEqual(a.shovelLoad, 0)
        XCTAssertEqual(b.shovelLoad, load)
    }

    func testDepositPileConservesAndPeaks() {
        let drift = Drift(width: 300)
        let accepted = drift.depositPile(atX: 150, amount: 1500)
        XCTAssertEqual(accepted, 1500, accuracy: 0.1)
        XCTAssertEqual(drift.totalSnow, 1500, accuracy: 0.1)
        XCTAssertGreaterThan(drift.height(atX: 150), drift.height(atX: 100) + 10)

        // Near the edge the heap widens inward instead of losing snow.
        let edge = Drift(width: 300)
        XCTAssertEqual(edge.depositPile(atX: 2, amount: 1500), 1500, accuracy: 0.1)
    }
}
