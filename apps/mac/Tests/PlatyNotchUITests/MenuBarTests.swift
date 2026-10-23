import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class MenuBarTests: XCTestCase {
    /// Without this, AppKit re-enables every item with a target and `isEnabled` is ignored.
    func testMenuDoesNotAutoenable() {
        XCTAssertFalse(MenuBarController.newMenu().autoenablesItems)
    }

    func testPauseItemDisabledWhenCaptureCannotRun() {
        XCTAssertEqual(MenuBarController.pauseItemState(.off).enabled, false)
        XCTAssertEqual(MenuBarController.pauseItemState(.needsAccessibility).enabled, false)
        XCTAssertEqual(MenuBarController.pauseItemState(.off).title, "Pause capture for 1 hour")
    }

    func testPauseItemEnabledWhileCapturingOrPaused() {
        XCTAssertEqual(MenuBarController.pauseItemState(.capturing).enabled, true)
        XCTAssertEqual(MenuBarController.pauseItemState(.capturing).title, "Pause capture for 1 hour")
        let paused = MenuBarController.pauseItemState(.paused(until: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(paused.enabled)
        XCTAssertTrue(paused.title.hasPrefix("Resume capture (paused until "), paused.title)
    }
}
