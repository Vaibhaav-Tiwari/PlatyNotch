import Foundation
import XCTest
@testable import PlatyNotchKit

final class UpdaterConfigTests: XCTestCase {
    let app = URL(fileURLWithPath: "/Applications/PlatyNotch.app")
    let feed = "https://vaibhaav-tiwari.github.io/PlatyNotch/appcast.xml"
    let key = "pfIShU4dEXqPd5ObYNfDBiQWcXozk7estwzTnF9BamQ="

    func testEnabledWithKeyAndFeedInBundle() {
        XCTAssertTrue(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": key, "SUFeedURL": feed], bundleURL: app))
    }

    func testDisabledWithoutKey() {
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUFeedURL": feed], bundleURL: app))
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": "", "SUFeedURL": feed], bundleURL: app))
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": "  \n", "SUFeedURL": feed], bundleURL: app))
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": 42, "SUFeedURL": feed], bundleURL: app))
    }

    func testDisabledWithoutHTTPSFeed() {
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": key], bundleURL: app))
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": key, "SUFeedURL": "http://x/appcast.xml"],
                                               bundleURL: app))
    }

    /// `swift run`: no bundle, no Info.plist.
    func testDisabledOutsideAppBundle() {
        XCTAssertFalse(UpdaterConfig.isEnabled(info: nil, bundleURL: URL(fileURLWithPath: "/tmp/.build/debug")))
        XCTAssertFalse(UpdaterConfig.isEnabled(info: ["SUPublicEDKey": key, "SUFeedURL": feed],
                                               bundleURL: URL(fileURLWithPath: "/tmp/.build/debug")))
    }

    func testReleasesPage() {
        XCTAssertEqual(UpdaterConfig.releasesURL.absoluteString, "https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases")
    }
}
