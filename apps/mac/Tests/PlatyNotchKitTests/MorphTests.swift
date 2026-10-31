import Foundation
import PlatyNotchKit
import XCTest

final class MorphTests: DefaultsTestCase {
    func testMatchesSameItem() {
        XCTAssertTrue(Morph.matches(pillTrailingID: "music:playing", heroTopID: "music:playing", motion: .calm))
        XCTAssertTrue(Morph.matches(pillTrailingID: "time:timer:1", heroTopID: "time:timer:1", motion: .calm))
        XCTAssertEqual(MorphID.live("music:playing"), MorphID.live("music:playing"))
        XCTAssertNotEqual(MorphID.live("a"), MorphID.platy)
    }

    func testNoMatchForDifferentItems() {
        XCTAssertFalse(Morph.matches(pillTrailingID: "music:playing", heroTopID: LiveItem.agentsID, motion: .calm),
                       "the hero shows the agents, the pill music: only Platy morphs")
        XCTAssertFalse(Morph.matches(pillTrailingID: nil, heroTopID: "music:playing", motion: .calm))
        XCTAssertFalse(Morph.matches(pillTrailingID: "music:playing", heroTopID: nil, motion: .calm))
        XCTAssertFalse(Morph.matches(pillTrailingID: nil, heroTopID: nil, motion: .calm))
        XCTAssertNotEqual(MorphID.live("a"), MorphID.live("b"))
    }

    func testReducedNeverMorphs() {
        XCTAssertFalse(Morph.matches(pillTrailingID: "music:playing", heroTopID: "music:playing", motion: .reduced))
        XCTAssertFalse(Morph.morphsPlaty(motion: .reduced))
        XCTAssertTrue(Morph.morphsPlaty(motion: .calm))
        XCTAssertTrue(Morph.morphsPlaty(motion: .calm))
    }
}
