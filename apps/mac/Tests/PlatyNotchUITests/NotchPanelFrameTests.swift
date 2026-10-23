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
}
