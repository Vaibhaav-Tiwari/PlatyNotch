import PlatyNotchKit
import XCTest

final class PermissionTableTests: XCTestCase {
    func testEveryPermissionHasARow() {
        XCTAssertEqual(PermissionTable.rows.map(\.id), PermissionID.allCases)
        for row in PermissionTable.rows {
            XCTAssertFalse(row.title.isEmpty)
            XCTAssertFalse(row.powers.isEmpty, "\(row.id)")
            XCTAssertFalse(row.withoutIt.isEmpty, "\(row.id)")
            XCTAssertFalse(row.powers.hasSuffix("."), "one plain phrase, no full stop: \(row.id)")
        }
        XCTAssertEqual(PermissionTable.row(.calendars).powers, "Next meeting, Join buttons and meeting reminders")
        XCTAssertEqual(PermissionTable.row(.calendars).withoutIt, "No meetings in Up next or the pill")
    }

    /// Camera and Bluetooth are asked only from their widget's own setting; Automation only
    /// from macOS. The table creates no new place a prompt can come from.
    func testNoNewRequestPaths() {
        XCTAssertEqual(PermissionTable.row(.camera).action, .openOwner(settingsSection: "widgets/mirror"))
        XCTAssertEqual(PermissionTable.row(.bluetooth).action, .openOwner(settingsSection: "widgets/system"))
        XCTAssertEqual(PermissionTable.row(.automation).action, .openSystemSettings)
        for id in [PermissionID.accessibility, .calendars, .reminders, .notifications] {
            XCTAssertEqual(PermissionTable.row(id).action, .request, "\(id) asks on a click, as today")
        }
    }

    /// Location powers Weather and is asked only on a click (Island spec 5).
    func testLocationRowForWeather() {
        let row = PermissionTable.row(.location)
        XCTAssertEqual(row.title, "Location")
        XCTAssertTrue(row.powers.contains("Weather"), row.powers)
        XCTAssertEqual(row.action, .request)
    }
}
