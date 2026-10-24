import XCTest
@testable import PlatyNotchKit

final class WidgetCategoryTests: DefaultsTestCase {
    private let power: Set<String> = ["mirror", "snap"]
    private func category(_ id: String) -> WidgetCategory { power.contains(id) ? .power : .everyday }

    func testDefaultsAndHeadings() {
        XCTAssertEqual(WidgetCategory.allCases, [.everyday, .power])
        XCTAssertNil(WidgetCategory.everyday.heading)
        XCTAssertEqual(WidgetCategory.power.heading, "Power features")
    }

    func testGroupedKeepsEachGroupsOrder() {
        let ids = ["mirror", "music", "snap", "shelf"]
        XCTAssertEqual(WidgetCategory.grouped(ids, category: category), ["music", "shelf", "mirror", "snap"])
    }

    func testReplacingOneGroupNeverMovesTheOther() {
        let current = ["music", "shelf", "mirror", "snap"]
        XCTAssertEqual(WidgetCategory.replacing(.power, with: ["snap", "mirror"], in: current, category: category),
                       ["music", "shelf", "snap", "mirror"])
        XCTAssertEqual(WidgetCategory.replacing(.everyday, with: ["shelf", "music"], in: current, category: category),
                       ["shelf", "music", "mirror", "snap"])
    }
}
