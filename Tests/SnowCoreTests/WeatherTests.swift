import XCTest
@testable import SnowCore

final class WeatherTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(SnowCore.version.isEmpty)
    }

    func testRngIsDeterministic() {
        var a = SplitMix64(seed: 42)
        var b = SplitMix64(seed: 42)
        for _ in 0..<100 { XCTAssertEqual(a.next(), b.next()) }
        var c = SplitMix64(seed: 7)
        for _ in 0..<1000 {
            let u = c.unit()
            XCTAssertGreaterThanOrEqual(u, 0)
            XCTAssertLessThan(u, 1)
        }
    }

    func testRectContains() {
        let r = Rect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(r.maxX, 110)
        XCTAssertEqual(r.maxY, 70)
        XCTAssertTrue(r.contains(SIMD2(10, 20)))
        XCTAssertFalse(r.contains(SIMD2(110, 30)))
        XCTAssertFalse(r.contains(SIMD2(50, 10)))
    }

    func testWindIsClamped() {
        XCTAssertEqual(Wind.calm, Wind(x: 0, y: 0))
        let w = Wind.calm.adjusted(dx: 3, dy: -0.5).adjusted(dx: 0, dy: -2)
        XCTAssertEqual(w.x, 1)
        XCTAssertEqual(w.y, -1)
        XCTAssertGreaterThan(w.fallMultiplier, 0)
    }

    func testPresetCapsScale() {
        XCTAssertEqual(SnowfallPreset.light.flakeCap(forWidth: 1440), 250)
        XCTAssertEqual(SnowfallPreset.steady.flakeCap(forWidth: 1440), 600)
        XCTAssertEqual(SnowfallPreset.blizzard.flakeCap(forWidth: 1440), 1500)
        XCTAssertEqual(SnowfallPreset.steady.flakeCap(forWidth: 720), 300)
        XCTAssertEqual(SnowfallPreset.steady.flakeCap(forWidth: 1440, budgetScale: 0.5), 300)
        XCTAssertEqual(SnowfallPreset.steady.flakeCap(forWidth: 1440, budgetScale: 0), 0)
    }
}
