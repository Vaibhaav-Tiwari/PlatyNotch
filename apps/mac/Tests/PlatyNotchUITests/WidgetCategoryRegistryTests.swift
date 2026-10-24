import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A widget with a chosen category and tile flag (R1).
@MainActor
private final class CategoryWidget: NotchWidget {
    let id: String
    let title: String
    let systemImage = "star"
    let defaultEnabled = true
    let hasTile: Bool
    let category: WidgetCategory
    var tileBuilds = 0

    init(_ id: String, category: WidgetCategory = .everyday, hasTile: Bool = true) {
        self.id = id
        title = id.capitalized
        self.category = category
        self.hasTile = hasTile
    }

    func tileView() -> AnyView {
        tileBuilds += 1
        return AnyView(Text(verbatim: title))
    }
}

/// A widget that relies on every default.
@MainActor
private final class PlainWidget: NotchWidget {
    let id = "plain"
    let title = "Plain"
    let systemImage = "star"
    let defaultEnabled = true
    func tileView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
final class WidgetCategoryRegistryTests: DefaultsTestCase {
    func testDefaultsAreEverydayWithATile() {
        let w = PlainWidget()
        XCTAssertTrue(w.hasTile)
        XCTAssertEqual(w.category, .everyday)
    }

    func testTodaySkipsWidgetsWithoutATile() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(CategoryWidget("music"))
        registry.register(CategoryWidget("snap", category: .power, hasTile: false))
        registry.register(CategoryWidget("mirror", category: .power))
        XCTAssertEqual(registry.visibleWidgets.map(\.id), ["music", "snap", "mirror"], "all are on")
        XCTAssertEqual(registry.tileWidgets.map(\.id), ["music", "mirror"], "a headless widget has no tile")
    }

    func testSettingsGroups() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(CategoryWidget("mirror", category: .power))
        registry.register(CategoryWidget("music"))
        registry.register(CategoryWidget("snap", category: .power))
        registry.register(CategoryWidget("shelf"))
        XCTAssertEqual(registry.orderedWidgets(in: .everyday).map(\.id), ["music", "shelf"])
        XCTAssertEqual(registry.orderedWidgets(in: .power).map(\.id), ["mirror", "snap"])

        registry.reorder(["snap", "mirror"], in: .power)
        XCTAssertEqual(registry.orderedWidgets(in: .power).map(\.id), ["snap", "mirror"])
        XCTAssertEqual(registry.orderedWidgets(in: .everyday).map(\.id), ["music", "shelf"], "the other group stays")
        XCTAssertEqual(registry.orderedWidgets.map(\.id), ["music", "shelf", "snap", "mirror"])

        registry.reorder(["shelf", "music"], in: .everyday)
        XCTAssertEqual(registry.orderedWidgets.map(\.id), ["shelf", "music", "snap", "mirror"])
    }

    /// Fix round 1: widgets on but none with a tile is not "no widgets are on".
    func testTodayEmptyMessage() {
        XCTAssertEqual(TodayTab.emptyMessage(enabledCount: 0).title, "No widgets are on.")
        XCTAssertEqual(TodayTab.emptyMessage(enabledCount: 2).title, "No tiles to show.")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(CategoryWidget("snap", category: .power, hasTile: false))
        XCTAssertTrue(registry.tileWidgets.isEmpty)
        XCTAssertEqual(TodayTab.emptyMessage(enabledCount: registry.visibleWidgets.count).title, "No tiles to show.")
        let view = NSHostingView(rootView: TodayTab(widgets: registry).frame(width: 360, height: 200))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, 0)
    }

    /// No power widget yet: no "Power features" group.
    func testNoPowerGroupWithoutPowerWidgets() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(CategoryWidget("music"))
        XCTAssertTrue(registry.orderedWidgets(in: .power).isEmpty)
    }

    /// The smoke build never lays out a tile a widget does not have.
    func testBuildViewsSkipsAMissingTile() {
        let headless = CategoryWidget("snap", category: .power, hasTile: false)
        XCTAssertTrue(AppDelegate.buildViews(of: headless))
        XCTAssertEqual(headless.tileBuilds, 0)
        let tiled = CategoryWidget("music")
        XCTAssertTrue(AppDelegate.buildViews(of: tiled))
        XCTAssertEqual(tiled.tileBuilds, 1)
    }

    /// Settings › Widgets builds with both groups.
    func testWidgetsSectionBuilds() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(CategoryWidget("music"))
        registry.register(CategoryWidget("snap", category: .power, hasTile: false))
        let view = NSHostingView(rootView: WidgetsSection(widgets: registry).frame(width: 520, height: 600))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(view.fittingSize.width, 0)
    }
}

/// `--smoke-power` (Task 0): every power feature built inert.
@MainActor
final class PowerSmokeTests: DefaultsTestCase {
    func testNoPowerFeaturesYet() {
        XCTAssertTrue(BuiltInWidgets.powerWidgets(persist: false).isEmpty)
        XCTAssertEqual(NotchApp.powerSmoke(BuiltInWidgets.powerWidgets(persist: false)), .success(0))
    }

    func testEveryListedWidgetMustBeAPowerFeature() {
        let everyday = CategoryWidget("music")
        XCTAssertEqual(NotchApp.powerSmoke([everyday]),
                       .failure(NotchApp.PowerSmokeFailure(message: "music is not a power feature")))
        let snap = CategoryWidget("snap", category: .power, hasTile: false)
        let mirror = CategoryWidget("mirror", category: .power)
        XCTAssertEqual(NotchApp.powerSmoke([snap, mirror]), .success(2))
        XCTAssertEqual(snap.tileBuilds, 0)
        XCTAssertEqual(mirror.tileBuilds, 1)
        XCTAssertEqual(NotchApp.powerSmoke([snap, snap]),
                       .failure(NotchApp.PowerSmokeFailure(message: "snap listed twice")))
    }
}
