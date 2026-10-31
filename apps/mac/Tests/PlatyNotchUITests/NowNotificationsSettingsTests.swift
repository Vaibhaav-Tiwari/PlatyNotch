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

    func testHomeOptionsDisableOffWidgets() {
        let o = HomeSection.options(notesOn: false, mailOn: true)
        XCTAssertEqual(o.map(\.column), [.upNext, .notes, .mail])
        XCTAssertEqual(o.map(\.enabled), [true, false, true])
        XCTAssertEqual(HomeSection.options(notesOn: true, mailOn: true).map(\.enabled), [true, true, true])
        XCTAssertEqual(HomeSection.options(notesOn: false, mailOn: false).map(\.enabled), [true, false, false])
    }

    /// Picking saves at once; an unavailable column is ignored, and a saved Notes choice shows
    /// as Up next while Notes is off.
    func testHomeModelSavesChoice() {
        let d = defaults()
        let r = registry()
        r.setEnabled(NotesWidget.widgetID, false)
        let model = HomeSettingsModel(widgets: r, defaults: d)
        XCTAssertEqual(model.rightColumn, .upNext)
        model.set(.notes)
        XCTAssertEqual(model.rightColumn, .upNext, "Notes is off: not offered")
        r.setEnabled(NotesWidget.widgetID, true)
        model.set(.notes)
        XCTAssertEqual(HomeSettings.load(from: d).rightColumn, .notes)
        XCTAssertEqual(model.effective, .notes)
        r.setEnabled(NotesWidget.widgetID, false)
        XCTAssertEqual(model.effective, .upNext, "falls back while the widget is off")
        XCTAssertEqual(HomeSettings.load(from: d).rightColumn, .notes, "the choice is kept for when it is back on")
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
