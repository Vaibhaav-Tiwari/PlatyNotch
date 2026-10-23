import Foundation
import PlatyNotchKit
import XCTest

final class WidgetLayoutTests: XCTestCase {
    func testLayoutDropsUnknownAppendsNew() {
        let layout = WidgetLayout(order: ["a", "gone", "c"], enabled: ["a", "b", "c", "gone"])
        // "gone" is not available (e.g. a plugin not installed): dropped. "b" is new and
        // enabled: appended. "d" is new but not enabled: not shown.
        XCTAssertEqual(layout.visible(available: ["d", "c", "b", "a"]), ["a", "c", "b"])
    }

    func testVisibleOnlyEnabled() {
        let layout = WidgetLayout(order: ["a", "b", "c"], enabled: ["a", "c"])
        XCTAssertEqual(layout.visible(available: ["a", "b", "c"]), ["a", "c"])
    }

    func testMove() {
        var layout = WidgetLayout(order: ["a", "b", "c", "d"], enabled: ["a", "b", "c", "d"])
        layout.move("d", to: 0)
        XCTAssertEqual(layout.order, ["d", "a", "b", "c"])
        layout.move("d", to: 2)
        XCTAssertEqual(layout.order, ["a", "b", "d", "c"])
        layout.move("a", to: 99)   // clamped to the end
        XCTAssertEqual(layout.order, ["b", "d", "c", "a"])
        layout.move("b", to: -3)
        XCTAssertEqual(layout.order, ["b", "d", "c", "a"])
        layout.move("new", to: 1)  // not yet ordered: inserted
        XCTAssertEqual(layout.order, ["b", "new", "d", "c", "a"])
    }

    func testReorderKeepsUnlistedIDs() {
        var layout = WidgetLayout(order: ["a", "gone", "b", "c"], enabled: [])
        layout.reorder(["c", "a", "b"])
        XCTAssertEqual(layout.order, ["c", "a", "b", "gone"])
    }

    /// C8: a new id is enabled only when its widget says so; a known id keeps the user's choice.
    func testAdoptEnablesNewIDsOnlyByDefault() {
        var layout = WidgetLayout()
        layout.adopt(id: "music", defaultEnabled: true)
        layout.adopt(id: "weather", defaultEnabled: false)
        XCTAssertEqual(layout.order, ["music", "weather"])
        XCTAssertEqual(layout.enabled, ["music"])

        layout.setEnabled("music", false)
        layout.setEnabled("weather", true)
        layout.adopt(id: "music", defaultEnabled: true)     // already known: the user's choice stays
        layout.adopt(id: "weather", defaultEnabled: false)
        XCTAssertEqual(layout.enabled, ["weather"])
        XCTAssertEqual(layout.order, ["music", "weather"])
    }

    func testCodableRoundTrip() throws {
        let layout = WidgetLayout(order: ["b", "a"], enabled: ["a"])
        let back = try JSONDecoder().decode(WidgetLayout.self, from: JSONEncoder().encode(layout))
        XCTAssertEqual(back, layout)
        XCTAssertNil(WidgetLayout.decode(Data("nonsense".utf8)))
        XCTAssertEqual(WidgetLayout.decode(layout.encoded()), layout)
    }
}
