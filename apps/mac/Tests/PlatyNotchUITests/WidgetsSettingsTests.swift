import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class WidgetsSettingsTests: DefaultsTestCase {
    private func registry() -> WidgetRegistry {
        let r = WidgetRegistry(defaults: defaults(), persist: false)
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, focus: FocusModel(defaults: defaults()))
        BuiltInWidgets.register(in: r, store: AppStore(), today: today, persist: false)
        return r
    }

    private func services(_ widgets: WidgetRegistry) -> SettingsServices {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return SettingsServices(config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                runner: CoreRunner(binaryURL: dir.appendingPathComponent("notch")),
                                store: AppStore(), capture: nil, calendar: CalendarService(eventKit: false),
                                reminders: RemindersService(eventKit: false), widgets: widgets,
                                updater: AppUpdater(start: false, enabled: false))
    }

    func testFiltersSplitCategories() {
        let model = WidgetsSettingsModel(widgets: registry())
        let everyday = model.shown(.everyday)
        let power = model.shown(.power)
        XCTAssertFalse(everyday.isEmpty)
        XCTAssertFalse(power.isEmpty)
        XCTAssertTrue(everyday.allSatisfy { $0.category == .everyday })
        XCTAssertTrue(power.allSatisfy { $0.category == .power })
        XCTAssertEqual(model.shown(.all).map(\.id), everyday.map(\.id) + power.map(\.id), "all: everyday, then power")
        XCTAssertTrue(power.contains { $0.id == BasketsWidget.widgetID })
    }

    func testDetailDeepLink() {
        let widgets = registry()
        let c = SettingsWindowController(services: services(widgets), pluginSections: [])
        c.model.go(to: SettingsTarget.resolve("widgets/music"), ids: c.sectionIDs)
        XCTAssertEqual(c.model.selection, "widgets")
        XCTAssertEqual(c.model.detail, "music")
        let model = WidgetsSettingsModel(widgets: widgets)
        XCTAssertEqual(model.widget(named: "music")?.id, MusicWidget.widgetID)
        XCTAssertEqual(model.widget(named: "fileactions")?.id, FileActionsWidget.widgetID, "links are lowercased")
        XCTAssertNil(model.widget(named: "nope"))
        // Picking another page leaves the detail behind.
        c.model.selection = "agents"
        XCTAssertNil(c.model.detail)
        // Old ids still land: approvals is an Agents sub-page.
        c.model.go(to: SettingsTarget.resolve("approvals"), ids: c.sectionIDs)
        XCTAssertEqual(c.model.selection, "agents")
        XCTAssertEqual(c.model.detail, "approvals")
        // An unknown section keeps the current page.
        c.model.go(to: SettingsTarget.resolve("com.example.unknown"), ids: c.sectionIDs)
        XCTAssertEqual(c.model.selection, "agents")
    }

    func testDragIsTheOnlyOrdering() {
        let widgets = registry()
        let model = WidgetsSettingsModel(widgets: widgets)
        let before = model.shown(.everyday).map(\.id)
        XCTAssertGreaterThan(before.count, 2)
        model.move(from: before[2], to: before[0])
        let after = model.shown(.everyday).map(\.id)
        XCTAssertEqual(after[0], before[2])
        XCTAssertEqual(Array(after[1...2]), Array(before[0...1]))
        // Never across groups.
        let power = model.shown(.power).map(\.id)
        model.move(from: power[0], to: after[0])
        XCTAssertEqual(model.shown(.everyday).map(\.id), after)
        XCTAssertEqual(model.shown(.power).map(\.id), power)
        // No up / down buttons remain in the Widgets page's source.
        let source = try? String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/PlatyNotchUITests/WidgetsSettingsTests.swift",
            with: "Sources/PlatyNotchUI/Settings/WidgetsSection.swift"), encoding: .utf8)
        XCTAssertNotNil(source)
        XCTAssertFalse(source?.contains("chevron.up") ?? true)
        XCTAssertFalse(source?.contains("chevron.down") ?? true)
        XCTAssertFalse(source?.contains("swapAt") ?? true)
    }

    /// Keyboard and VoiceOver: "Move earlier" and "Move later" step a card within its group.
    func testMoveActionsStepWithinTheGroup() {
        let model = WidgetsSettingsModel(widgets: registry())
        let before = model.shown(.everyday).map(\.id)
        model.moveLater(before[0])
        XCTAssertEqual(Array(model.shown(.everyday).map(\.id).prefix(2)), [before[1], before[0]])
        model.moveEarlier(before[0])
        XCTAssertEqual(model.shown(.everyday).map(\.id), before)
        model.moveEarlier(before[0])
        XCTAssertEqual(model.shown(.everyday).map(\.id), before, "the first stays first")
        let power = model.shown(.power).map(\.id)
        model.moveLater(power.last!)
        XCTAssertEqual(model.shown(.power).map(\.id), power, "the last stays last; never into another group")
    }

    func testCardStatusLine() {
        XCTAssertEqual(WidgetCard.status(isOn: true, needsSetup: false, inLibrary: true), "On · in Library")
        XCTAssertEqual(WidgetCard.status(isOn: true, needsSetup: true, inLibrary: true), "Needs setup")
        XCTAssertEqual(WidgetCard.status(isOn: false, needsSetup: true, inLibrary: true), "Off")
        XCTAssertEqual(WidgetCard.status(isOn: true, needsSetup: false, inLibrary: false), "On")
    }
}
