import XCTest
@testable import PlatyNotchKit

final class LaunchOptionsTests: XCTestCase {
    func testDefaults() {
        let o = LaunchOptions(arguments: ["PlatyNotch"], env: [:])
        XCTAssertFalse(o.smoke)
        XCTAssertEqual(o.smokeDelay, 3)
        XCTAssertFalse(o.externalCore)
    }

    func testSmokeAndOverrides() {
        let o = LaunchOptions(arguments: ["PlatyNotch", "--smoke"],
                              env: ["PLATYNOTCH_SMOKE_DELAY": "8", "PLATYNOTCH_EXTERNAL_CORE": "1"])
        XCTAssertTrue(o.smoke)
        XCTAssertEqual(o.smokeDelay, 8)
        XCTAssertTrue(o.externalCore)
        XCTAssertEqual(LaunchOptions(arguments: [], env: ["PLATYNOTCH_SMOKE_DELAY": "nope"]).smokeDelay, 3)
        XCTAssertFalse(LaunchOptions(arguments: [], env: ["PLATYNOTCH_EXTERNAL_CORE": "0"]).externalCore)
    }
}

extension LaunchOptionsTests {
    func testSmokeSettingsFlag() {
        let o = LaunchOptions(arguments: ["PlatyNotch", "--smoke-settings"], env: [:])
        XCTAssertTrue(o.smokeSettings)
        XCTAssertFalse(o.smoke)
        XCTAssertFalse(LaunchOptions(arguments: ["PlatyNotch", "--smoke"], env: [:]).smokeSettings)
    }
}
