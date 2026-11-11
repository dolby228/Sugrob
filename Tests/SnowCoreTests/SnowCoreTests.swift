import XCTest
@testable import SnowCore

final class SnowCoreTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(SnowCore.version.isEmpty)
    }
}
