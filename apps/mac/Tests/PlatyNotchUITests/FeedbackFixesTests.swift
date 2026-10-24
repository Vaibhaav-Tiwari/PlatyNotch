import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// User feedback round 1: Settings from inside the notch (11), Calendar from the notch (8).
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

    // MARK: - 8. Calendar / Reminders access from the notch

    /// What a prompt request did, in order.
    private final class FocusLog {
        var steps: [String] = []
        var active = false
        var front: pid_t? = 4242
    }

    private func focus(_ log: FocusLog) -> PromptFocus {
        PromptFocus(isActive: { log.active },
                    frontmost: { log.front },
                    activate: { log.steps.append("activate"); log.active = true },
                    restore: { log.steps.append("restore \($0)") })
    }

    /// The notch panel never activates the app, and EventKit shows its prompt only for the
    /// active app: the request from the tile activates PlatyNotch first and gives the
    /// keyboard back to the app that had it once answered.
    func testCalendarRequestFromTheNotchActivatesTheAppFirst() async {
        let log = FocusLog()
        var status = CalendarService.Access.notAsked
        let calendar = CalendarService(seam: .init(status: { status }, request: {
            log.steps.append("request active=\(log.active)")
            status = .granted
            return true
        }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, ["activate", "request active=true", "restore 4242"])
        XCTAssertEqual(calendar.access, .granted)
    }

    func testRemindersRequestFromTheNotchActivatesTheAppFirst() async {
        let log = FocusLog()
        var status = RemindersService.Access.notAsked
        let reminders = RemindersService(seam: .init(status: { status }, request: {
            log.steps.append("request active=\(log.active)")
            status = .denied
            return false
        }), focus: focus(log), defaults: defaults())
        await reminders.requestAccess()
        XCTAssertEqual(log.steps, ["activate", "request active=true", "restore 4242"])
        XCTAssertEqual(reminders.access, .denied)
    }

    /// Already active (the Settings window): nothing is activated or handed back.
    func testRequestWhileActiveLeavesFocusAlone() async {
        let log = FocusLog()
        log.active = true
        let calendar = CalendarService(seam: .init(status: { .notAsked }, request: { true }), focus: focus(log))
        await calendar.requestAccess()
        XCTAssertEqual(log.steps, [])
    }
}
