import AppKit
import XCTest
@testable import PlatyNotchUI

/// Regression: AppKit pushes windows below the menu bar unless the panel opts out,
/// which put the notch panel one menu-bar height below the camera housing.
@MainActor
final class NotchPanelFrameTests: XCTestCase {
    /// Every panel these tests make sits here, never where the user works.
    static let offScreen = CGRect(x: -10_000, y: 10_000, width: 10, height: 10)

    func testPanelKeepsFrameAtScreenTop() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = NSRect(x: screen.frame.midX - 280, y: screen.frame.maxY - 380, width: 560, height: 380)
        let panel = NotchPanel(frame: Self.offScreen)
        // AppKit's own constraint, asked for the top of the real screen without ever
        // showing the panel there.
        XCTAssertEqual(panel.constrainFrameRect(frame, to: screen), frame, "panel was pushed below the menu bar")
        // And ordered in (off screen, never where the user works) it keeps exactly its frame.
        let away = NSRect(x: -10_000, y: 10_000, width: 560, height: 380)
        panel.setFrame(away, display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertEqual(panel.frame, away)
    }

    /// Regression (Task 6 fix round 1): `isFloatingPanel` reset `.statusBar` to `.floating`.
    func testPanelSitsAtStatusBarLevel() {
        let panel = NotchPanel(frame: Self.offScreen)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.isFloatingPanel)
    }

    /// Final review A4: the panel becomes key only after a click in it, never because
    /// another of PlatyNotch's windows closed; losing key needs a new click.
    /// Final re-review A4: a click while the mode cannot take the keyboard (the compact
    /// pill, a notice) must not linger until an approval peek shows.
    func testClickOutsideAKeyModeIsForgotten() {
        let panel = NotchPanel(frame: Self.offScreen)
        panel.allowsKey = false
        panel.noteMouseDown()                       // a click on the pill
        panel.allowsKey = true                      // later: the approval peek
        XCTAssertFalse(panel.canBecomeKey, "the pill click does not count for the approval")
    }

    /// Leaving the key mode forgets a click.
    func testLeavingTheKeyModeForgetsTheClick() {
        let panel = NotchPanel(frame: Self.offScreen)
        panel.allowsKey = true
        panel.noteMouseDown()
        XCTAssertTrue(panel.canBecomeKey)
        panel.allowsKey = false
        panel.allowsKey = true
        XCTAssertFalse(panel.canBecomeKey, "leaving the key mode forgets the click")
    }

    func testKeyOnlyAfterAClickInThePanel() {
        let panel = NotchPanel(frame: Self.offScreen)
        panel.allowsKey = true
        XCTAssertFalse(panel.canBecomeKey, "no click yet: Settings closing must not hand it key")
        panel.noteMouseDown()
        XCTAssertTrue(panel.canBecomeKey)
        panel.allowsKey = false
        XCTAssertFalse(panel.canBecomeKey, "the mode still decides")
        panel.allowsKey = true
        panel.resignKey()
        XCTAssertFalse(panel.canBecomeKey, "after losing key a new click is needed")
        XCTAssertTrue(NotchPanel.isPress(.leftMouseDown))
        XCTAssertFalse(NotchPanel.isPress(.rightMouseDown), "right clicks never hand it the keyboard")
        XCTAssertFalse(NotchPanel.isPress(.mouseMoved))
        XCTAssertFalse(NotchPanel.isPress(.keyDown))
    }
}
