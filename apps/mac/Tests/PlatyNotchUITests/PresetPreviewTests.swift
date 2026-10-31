import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Settings › General's live preview of a preset (Island spec 6).
@MainActor
final class PresetPreviewTests: DefaultsTestCase {
    func testPreviewShowsPresetDock() {
        XCTAssertEqual(PresetPreview.dockLabels(.developer),
                       ["Timer", "Note", "Remind", "Clipboard", "Shelf", "Memory", "\u{2325}\u{2318}K"])
        XCTAssertEqual(PresetPreview.dockLabels(.everyday),
                       ["Timer", "Note", "Remind", "Clipboard", "Shelf", "Games", "\u{2325}\u{2318}K"])
        XCTAssertEqual(PresetPreview.dockLabels(.minimal), ["All tools"])
        XCTAssertEqual(PresetPreview.scale, 0.6)
    }

    func testEachPresetLooksDifferent() {
        let looks = SetupPreset.allCases.map { PresetPreview.texts($0) }
        XCTAssertEqual(Set(looks).count, 3, "\(looks)")
        XCTAssertTrue(PresetPreview.texts(.developer).contains("Agents"))
        XCTAssertFalse(PresetPreview.texts(.everyday).contains("Agents"))
        XCTAssertTrue(PresetPreview.texts(.minimal).contains("Hidden until something is live"))
    }

    func testPreviewDoesNotApply() {
        let keys = [DockLayout.key, IslandPrefs.key, WidgetLayout.key, AppearanceStore.key, AgentsVisibility.key]
        let before = keys.map { UserDefaults.standard.data(forKey: $0) }
        for p in SetupPreset.allCases {
            let host = NSHostingView(rootView: PresetPreview(preset: p))
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 10000, width: 420, height: 400),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            host.display()
            XCTAssertGreaterThan(host.fittingSize.height, 0)
            window.contentView = nil
        }
        XCTAssertEqual(keys.map { UserDefaults.standard.data(forKey: $0) }, before, "only Apply writes")
        XCTAssertNil(defaults().data(forKey: DockLayout.key))
    }

    /// Apply writes the dock, the Island choices and Agents together (the real panel then
    /// reads them), not only widgets.
    func testApplyWritesDockPillAndAgents() {
        let d = defaults()
        SettingsServices.applyLayout(.developer, defaults: d)
        XCTAssertEqual(DockLayout.load(from: d), SetupPreset.developer.layout.dock)
        XCTAssertEqual(IslandPrefs.load(from: d).pillOrder, .agentsFirst)
        XCTAssertTrue(AgentsVisibility.load(from: d).isVisible, "Developer: Agents always")
        SettingsServices.applyLayout(.minimal, defaults: d)
        XCTAssertTrue(IslandPrefs.load(from: d).dockFolded)
        XCTAssertFalse(AgentsVisibility.load(from: d).forcedOn, "Minimal: once hooks are set up")
        SettingsServices.applyLayout(.everyday, defaults: d)
        XCTAssertEqual(IslandPrefs.load(from: d), IslandPrefs())
        XCTAssertEqual(DockLayout.load(from: d).slots.dropLast().last, .core(.games))
    }

    func testRealPanelFoldsTheDock() {
        let r = HomeRenders.builtIns(meeting: false)
        func panel(_ prefs: IslandPrefs) -> ExpandedPanel {
            ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                          today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                          extraTabs: [], route: .constant(PanelRoute(destination: .home)), onCollapse: {},
                          islandPrefs: prefs, onDecide: { _, _ in }, onOpenTerminal: { _ in })
        }
        XCTAssertTrue(panel(SetupPreset.minimal.layout.prefs).homeView.foldedDock)
        XCTAssertFalse(panel(SetupPreset.everyday.layout.prefs).homeView.foldedDock)
    }
}
