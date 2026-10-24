import AppKit
import XCTest
@testable import PlatyNotchUI

/// Regression: AppKit pushes windows below the menu bar unless the panel opts out,
/// which put the notch panel one menu-bar height below the camera housing.
@MainActor
final class NotchPanelFrameTests: XCTestCase {
    func testPanelKeepsFrameAtScreenTop() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let frame = NSRect(x: screen.frame.midX - 280, y: screen.frame.maxY - 380, width: 560, height: 380)
        let panel = NotchPanel(frame: .zero)
        // Through AppKit's own path: ordering a window in constrains its frame to the
        // screen (clear and click-through, so nothing visible happens).
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        XCTAssertEqual(panel.frame.maxY, screen.frame.maxY, "panel was pushed below the menu bar")
        XCTAssertEqual(panel.frame, frame)
    }

    /// Regression (Task 6 fix round 1): `isFloatingPanel` reset `.statusBar` to `.floating`.
    func testPanelSitsAtStatusBarLevel() {
        let panel = NotchPanel(frame: .zero)
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertTrue(panel.isFloatingPanel)
    }

    /// Final review A4: the panel becomes key only after a click in it, never because
    /// another of PlatyNotch's windows closed; losing key needs a new click.
    func testKeyOnlyAfterAClickInThePanel() {
        let panel = NotchPanel(frame: .zero)
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
        XCTAssertTrue(NotchPanel.isPress(.rightMouseDown))
        XCTAssertFalse(NotchPanel.isPress(.mouseMoved))
        XCTAssertFalse(NotchPanel.isPress(.keyDown))
    }
}
