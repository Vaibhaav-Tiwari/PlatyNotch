import Foundation
import PlatyNotchKit
import XCTest

final class HomeSettingsTests: DefaultsTestCase {
    func testDefaultIsUpNext() {
        XCTAssertEqual(HomeSettings().rightColumn, .upNext)
        XCTAssertEqual(HomeSettings.load(from: defaults()), HomeSettings())
        XCTAssertEqual(HomeSettings.key, "home.settings")
    }

    func testRoundTrip() {
        HomeSettings(rightColumn: .mail).save(to: defaults())
        XCTAssertEqual(HomeSettings.load(from: defaults()).rightColumn, .mail)
        HomeSettings(rightColumn: .notes).save(to: defaults())
        XCTAssertEqual(HomeSettings.load(from: defaults()).rightColumn, .notes)
    }

    func testDamagedValueLoadsDefault() {
        defaults().set(Data("damaged".utf8), forKey: HomeSettings.key)
        XCTAssertEqual(HomeSettings.load(from: defaults()), HomeSettings())
        defaults().set(Data(#"{"rightColumn":"weather"}"#.utf8), forKey: HomeSettings.key)
        XCTAssertEqual(HomeSettings.load(from: defaults()).rightColumn, .upNext, "an unknown column")
        defaults().set("not data", forKey: HomeSettings.key)
        XCTAssertEqual(HomeSettings.load(from: defaults()), HomeSettings())
    }
}
