import XCTest
@testable import SnowCore

final class DriftTests: XCTestCase {
    func testColumnsCoverWidth() {
        let drift = Drift(width: 401, columnSpacing: 4)
        XCTAssertLessThanOrEqual(drift.columnSpacing, 4)
        XCTAssertEqual(drift.columnX(drift.columnCount - 1), 401, accuracy: 1e-3)
        XCTAssertEqual(drift.totalSnow, 0)
    }

    func testDepositAddsExactAmount() {
        let drift = Drift(width: 200)
        let accepted = drift.deposit(atX: 51, amount: 12)
        XCTAssertEqual(accepted, 12, accuracy: 1e-4)
        XCTAssertEqual(drift.totalSnow, 12, accuracy: 1e-4)
        XCTAssertGreaterThan(drift.height(atX: 51), 0)
        XCTAssertEqual(drift.height(atX: -5), 0)
        XCTAssertEqual(drift.height(atX: 250), 0)
        XCTAssertEqual(drift.deposit(atX: 300, amount: 5), 0)
    }

    func testDepositRespectsMaxHeight() {
        let drift = Drift(width: 100, maxHeight: 10)
        for _ in 0..<100 { drift.deposit(atX: 50, amount: 20) }
        XCTAssertLessThanOrEqual(drift.peakHeight, 10 + 1e-4)
    }

    func testSettleConservesSnowAndLimitsSlope() {
        let drift = Drift(width: 400)
        var deposited: Float = 0
        var spilled: Float = 0
        for i in 0..<400 {
            deposited += drift.deposit(atX: 200 + Float(i % 7) - 3, amount: 6)
            spilled += drift.settle()
        }
        for _ in 0..<500 { spilled += drift.settle() }

        XCTAssertGreaterThan(deposited, 0)
        XCTAssertEqual(drift.totalSnow + spilled, deposited, accuracy: deposited * 1e-4)

        let maxStep = drift.reposeSlope * drift.columnSpacing
        for i in 0..<(drift.columnCount - 1) {
            let diff = abs(drift.heights[i + 1] - drift.heights[i])
            XCTAssertLessThanOrEqual(diff, maxStep + 1e-3, "slope too steep at column \(i)")
        }
        // A bank: highest in the middle, thin at the edges.
        XCTAssertGreaterThan(drift.height(atX: 200), drift.height(atX: 20))
        XCTAssertLessThanOrEqual(drift.heights[0], maxStep * drift.edgeHold + 1e-3)
    }

    func testSettleSpillsOffEdges() {
        let drift = Drift(width: 40)
        for x in stride(from: Float(0), through: 40, by: 2) {
            drift.deposit(atX: x, amount: 40)
        }
        let before = drift.totalSnow
        var spilled: Float = 0
        for _ in 0..<200 { spilled += drift.settle() }
        XCTAssertGreaterThan(spilled, 0)
        XCTAssertEqual(drift.totalSnow + spilled, before, accuracy: before * 1e-4)
    }

    func testSettleWithoutSteepSlopesMovesNothing() {
        let drift = Drift(width: 400)
        for x in stride(from: Float(100), through: 300, by: 2) {
            drift.deposit(atX: x, amount: 1)
        }
        for _ in 0..<50 { drift.settle() }
        let before = drift.heights
        let spilled = drift.settle(passes: 5)
        XCTAssertEqual(spilled, 0)
        XCTAssertEqual(drift.heights, before)
    }

    func testSweepRemovesSnowUnderCircle() {
        let drift = Drift(width: 400)
        for x in stride(from: Float(0), through: 400, by: 2) {
            drift.deposit(atX: x, amount: 20)
        }
        let before = drift.totalSnow
        let farBefore = drift.height(atX: 300)
        let removed = drift.sweep(center: SIMD2(200, -2), radius: 12)

        XCTAssertGreaterThan(removed, 0)
        XCTAssertEqual(drift.totalSnow, before - removed, accuracy: 1e-2)
        XCTAssertEqual(drift.height(atX: 200), 0, accuracy: 1e-4)
        XCTAssertEqual(drift.height(atX: 300), farBefore, accuracy: 1e-4)
    }

    func testSweepAwayFromSnowRemovesNothing() {
        let drift = Drift(width: 100)
        drift.deposit(atX: 50, amount: 8)
        XCTAssertEqual(drift.sweep(center: SIMD2(50, -100), radius: 10), 0)
        XCTAssertEqual(drift.sweep(center: SIMD2(500, 0), radius: 10), 0)
        XCTAssertEqual(drift.totalSnow, 8, accuracy: 1e-4)
    }

    func testSweepOverTopKeepsSnowBelowCircle() {
        let drift = Drift(width: 100)
        for x in stride(from: Float(40), through: 60, by: 1) {
            drift.deposit(atX: x, amount: 30)
        }
        let h = drift.height(atX: 50)
        XCTAssertGreaterThan(h, 10)
        drift.sweep(center: SIMD2(50, -h - 2), radius: 6)
        // Columns at x = 48 and 52 are 2 pt from the center.
        let expected = h + 2 - Float(32).squareRoot()
        XCTAssertEqual(drift.height(atX: 50), expected, accuracy: 1e-3)
    }

    func testResizeShrinkLosesSnowPastEdge() {
        let drift = Drift(width: 200)
        drift.deposit(atX: 50, amount: 10)
        drift.deposit(atX: 150, amount: 10)
        let lost = drift.resize(width: 100)
        XCTAssertEqual(drift.width, 100)
        XCTAssertGreaterThan(lost, 5)
        XCTAssertGreaterThan(drift.height(atX: 50), 0)
    }

    func testResizeGrowKeepsSnow() {
        let drift = Drift(width: 100)
        drift.deposit(atX: 52, amount: 10)
        let lost = drift.resize(width: 300)
        XCTAssertEqual(lost, 0, accuracy: 1e-4)
        XCTAssertEqual(drift.totalSnow, 10, accuracy: 0.5)
        XCTAssertEqual(drift.height(atX: 250), 0)
    }

    func testClearAndRemoveFraction() {
        let drift = Drift(width: 100)
        drift.deposit(atX: 50, amount: 10)
        XCTAssertEqual(drift.remove(fraction: 0.5), 5, accuracy: 1e-4)
        XCTAssertEqual(drift.clear(), 5, accuracy: 1e-4)
        XCTAssertTrue(drift.isEmpty)
    }
}
