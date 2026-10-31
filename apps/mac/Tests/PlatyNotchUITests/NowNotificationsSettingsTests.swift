import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class NowNotificationsSettingsTests: DefaultsTestCase {
    private func registry() -> WidgetRegistry {
        let r = WidgetRegistry(defaults: defaults(), persist: false)
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, focus: FocusModel(defaults: defaults()))
        BuiltInWidgets.register(in: r, store: AppStore(), today: today, persist: false)
        return r
    }

    /// Settings › Home's Weather group reads the weather widget; turning "Use my location"
    /// off goes back to the city without asking anything.
    func testHomeWeatherGroup() {
        let r = registry()
        let model = HomeSettingsModel(widgets: r, defaults: defaults())
        let weather = try? XCTUnwrap(model.weather)
        XCTAssertNotNil(weather)
        XCTAssertFalse(model.weatherOn, "off until a preset or the user turns it on")
        r.setEnabled(WeatherWidget.widgetID, true)
        XCTAssertTrue(model.weatherOn)
        model.setUseMyLocation(false)
        XCTAssertFalse(weather?.usesMyLocation ?? true)
        r.stopAll()
    }

    func testLockedApprovalToggles() {
        let d = defaults()
        let model = NotificationsModel(defaults: d)
        XCTAssertEqual(model.cell(.approval, .showInPill), .locked("Always"))
        XCTAssertEqual(model.cell(.approval, .canOpen), .locked("Always"))
        XCTAssertEqual(model.cell(.approval, .quietDuringFocus), .locked("Never"))
        model.set(.approval, .canOpen, false)
        XCTAssertEqual(model.cell(.approval, .canOpen), .locked("Always"), "a locked cell never changes")
        XCTAssertEqual(model.cell(.other, .canOpen), .toggle(false))
        model.set(.other, .canOpen, true)
        XCTAssertEqual(NotificationPolicy.load(from: d)[.other].canOpen, true, "saved at once")
        for kind in NotificationKind.where({ $0 != .approval }) {
            for field in NotificationsModel.fields {
                guard case .toggle = model.cell(kind, field) else { return XCTFail("\(kind) \(field) is a switch") }
            }
        }
        XCTAssertEqual(NotificationKind.allCases.map(NotificationsModel.title),
                       ["Approvals", "Agent needs you or stopped", "Agent finished", "Alarms and timers",
                        "Meeting starting", "Reminders you asked for", "Everything else", "Plug-ins without a kind"])
    }

}

private extension NotificationKind {
    static func `where`(_ keep: (NotificationKind) -> Bool) -> [NotificationKind] { allCases.filter(keep) }
}
