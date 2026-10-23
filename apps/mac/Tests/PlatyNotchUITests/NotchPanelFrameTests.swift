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
        let panel = NotchPanel(frame: frame)
        XCTAssertEqual(panel.constrainFrameRect(frame, to: screen), frame)
        let aboveTop = frame.offsetBy(dx: 0, dy: 40)
        XCTAssertEqual(panel.constrainFrameRect(aboveTop, to: screen), aboveTop)
    }
}
