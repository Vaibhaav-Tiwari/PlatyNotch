import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// User feedback round 1: Settings from inside the notch (11).
@MainActor
final class FeedbackFixesTests: DefaultsTestCase {
    private var mbpLayout: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32))
    }

    private func controller() -> NotchController {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let c = NotchController(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"), plugins: [],
                                widgets: registry, surfaces: PanelSurfaces(registry: registry))
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        c.debugHandle(.layout(mbpLayout))
        return c
    }

    /// The open panel's gear opens Settings through the app (the menu bar icon may be
    /// hidden) and changes nothing in the panel: no collapse, no approval answered.
    func testGearInTheOpenPanelOpensSettings() {
        let c = controller()
        var opened = 0
        c.onOpenSettings = { opened += 1 }
        c.expand()
        XCTAssertEqual(c.mode, .expanded)
        c.model.onOpenSettings()
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(c.mode, .expanded)
    }

    func testSettingsURLRoutes() {
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings")!), .settings(section: nil))
        XCTAssertEqual(AppURL.route(URL(string: "platynotch://settings/widgets")!), .settings(section: "widgets"))
    }
}
