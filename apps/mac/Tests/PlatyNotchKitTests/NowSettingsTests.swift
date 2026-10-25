import Foundation
import PlatyNotchKit
import XCTest

final class NowSettingsTests: DefaultsTestCase {
    func testNowSettingsMissingKeyCycles() {
        XCTAssertTrue(NowSettings.load(from: defaults()).heroCycling, "nothing saved: the hero steps through live items")
        defaults().set(Data("damaged".utf8), forKey: NowSettings.key)
        XCTAssertTrue(NowSettings.load(from: defaults()).heroCycling)
        XCTAssertEqual(NowSettings(), NowSettings(heroCycling: true))
    }

    func testNowSettingsRoundTrip() {
        NowSettings(heroCycling: false).save(to: defaults())
        XCTAssertEqual(NowSettings.load(from: defaults()), NowSettings(heroCycling: false))
        NowSettings(heroCycling: true).save(to: defaults())
        XCTAssertTrue(NowSettings.load(from: defaults()).heroCycling)
    }
}
