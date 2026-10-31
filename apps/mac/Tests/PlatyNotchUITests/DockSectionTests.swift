import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Settings › Dock (Island spec 6): reorder, at most 8, Search stays, off tools turn on.
@MainActor
final class DockSectionTests: DefaultsTestCase {
    private func model() -> (DockSettingsModel, WidgetRegistry) {
        let r = HomeRenders.builtIns(meeting: false)
        return (DockSettingsModel(widgets: r.registry, defaults: defaults()), r.registry)
    }

    func testReorderSaves() {
        let (m, _) = model()
        let games: Int = m.layout.slots.firstIndex(of: .core(.games))!
        m.move(from: IndexSet(integer: games), to: 0)
        XCTAssertEqual(DockLayout.load(from: defaults()).slots.first, .core(.games))
        XCTAssertEqual(m.layout.slots.first, .core(.games))
    }

    func testNinthPickRefused() {
        let (m, _) = model()
        XCTAssertEqual(m.layout.slots.count, 8)
        XCTAssertEqual(DockSection.counter(m.layout), "8 of 8")
        let before = m.layout
        m.set(.tool("baskets"), on: true)
        XCTAssertEqual(m.message, "The dock holds 8.")
        XCTAssertEqual(m.layout, before)
        XCTAssertNil(defaults().data(forKey: DockLayout.key), "a refused pick saves nothing")
        m.set(.core(.games), on: false)
        XCTAssertEqual(DockSection.counter(m.layout), "7 of 8")
        XCTAssertNil(m.message)
        m.set(.tool("baskets"), on: true)
        XCTAssertEqual(DockLayout.load(from: defaults()).slots.dropLast().last, .tool("baskets"), "added before Search")
    }

    func testSearchCannotBeUnticked() {
        let (m, _) = model()
        XCTAssertFalse(DockSection.canToggle(.core(.search), in: m.layout))
        XCTAssertTrue(DockSection.canToggle(.core(.games), in: m.layout))
        m.set(.core(.search), on: false)
        XCTAssertTrue(m.layout.slots.contains(.core(.search)))
    }

    func testPickingOffToolTurnsItOn() {
        let (m, registry) = model()
        registry.setEnabled("notes", false)
        m.set(.core(.note), on: false)
        XCTAssertFalse(registry.isEnabled("notes"))
        m.set(.core(.note), on: true)
        XCTAssertTrue(registry.isEnabled("notes"), "picking a tool whose widget is off turns it on")
        XCTAssertTrue(m.layout.slots.contains(.core(.note)))
    }

    func testChoicesListCoreToolsThenOthers() {
        let (m, _) = model()
        let ids = m.choices.map(\.slot)
        XCTAssertEqual(Array(ids.prefix(8)), DockTool.allCases.map(DockSlot.core))
        XCTAssertTrue(ids.contains(.tool("baskets")))
        XCTAssertFalse(ids.contains(.tool("notes")), "a core tool's widget is not offered twice")
    }

    func testFoldSwitchSaves() {
        let (m, _) = model()
        m.setFolded(true)
        XCTAssertTrue(IslandPrefs.load(from: defaults()).dockFolded)
    }
}
