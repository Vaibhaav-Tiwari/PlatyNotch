import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A widget with only the required members and a tile, the way a plugin written before
/// the redesign looks.
@MainActor
private final class TileOnlyWidget: NotchWidget {
    let id: String
    let title = "Tile only"
    let systemImage = "star"
    let defaultEnabled = true
    var live: [LiveActivity] = []
    var liveActivities: [LiveActivity] { live }

    init(_ id: String = "fake") { self.id = id }

    func tileView() -> AnyView { AnyView(Text(verbatim: "TILE").frame(width: 120, height: 40)) }
}

/// A headless glance widget with settings and its own content flag.
@MainActor
private final class GlanceWidget: NotchWidget {
    let id: String
    let title = "Glance"
    let systemImage = "sun.max"
    let defaultEnabled = true
    var hasTile: Bool { false }
    var kind: WidgetKind { [.glance, .tool] }
    var content = true
    var hasContent: Bool { content }
    var setup: WidgetSetupAction = .openSettings
    var setupAction: WidgetSetupAction { setup }

    init(_ id: String) { self.id = id }

    func tileView() -> AnyView { AnyView(EmptyView()) }
    func settingsView() -> AnyView? { AnyView(Text(verbatim: "SETTINGS").frame(width: 200, height: 30)) }
    func glanceView() -> AnyView? { AnyView(Text(verbatim: "24° Clear")) }
}

@MainActor
final class WidgetKindAPITests: DefaultsTestCase {
    private func context() -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnkind\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                             openPanel: { _ in })
    }

    private func width(_ view: AnyView) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    func testTileOnlyWidgetIsATool() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let w = TileOnlyWidget()
        registry.register(w)
        registry.start(context: context())
        XCTAssertEqual(w.kind, .tool)
        XCTAssertTrue(w.hasContent)
        XCTAssertNil(w.heroView())
        XCTAssertNil(w.glanceView())
        XCTAssertNil(w.libraryTile())
        XCTAssertEqual(registry.toolWidgets.map(\.id), ["fake"])
    }

    func testToolViewDefaultsToTile() {
        let w = TileOnlyWidget()
        XCTAssertEqual(width(w.toolView()), 120)
    }

    func testHeadlessToolViewIsSettings() {
        let w = GlanceWidget("weather")
        XCTAssertEqual(width(w.toolView()), 200)
    }

    func testRunSetupDefaultOpensSettings() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(GlanceWidget("fake"))
        var opened: [String] = []
        registry.openSettingsHandler = { opened.append($0) }
        registry.runSetup("fake")
        XCTAssertEqual(opened, ["widgets/fake"])
        registry.runSetup("missing")
        XCTAssertEqual(opened, ["widgets/fake"], "unknown ids do nothing")
    }

    func testRunSetupCustomAction() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let w = GlanceWidget("fake")
        var ran = 0
        w.setup = .run { ran += 1 }
        registry.register(w)
        var opened: [String] = []
        registry.openSettingsHandler = { opened.append($0) }
        registry.runSetup("fake")
        XCTAssertEqual(ran, 1)
        XCTAssertTrue(opened.isEmpty)
    }

    func testRankedLiveUsesRunningWidgetsOnly() {
        let now = Date(timeIntervalSince1970: 5_000_000)
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let on = TileOnlyWidget("on")
        let off = TileOnlyWidget("off")
        on.live = [LiveActivity(id: "on:1", widgetID: "on", priority: LivePriority.musicPlaying, glyph: .musicBars)]
        off.live = [LiveActivity(id: "off:1", widgetID: "off", priority: LivePriority.alarmRinging, glyph: .musicBars)]
        registry.register(on)
        registry.register(off)
        registry.setEnabled("off", false)
        registry.start(context: context())
        let agents = AgentsLive(rank: .agentNeedsYou, title: "Codex", subtitle: nil, startedAt: now,
                                needsYou: 1, working: 0, total: 1)
        XCTAssertEqual(registry.rankedLive(agents: agents, now: now).map(\.id), [LiveItem.agentsID, "on:1"])
        XCTAssertEqual(registry.rankedLive(agents: nil, now: now).map(\.id), ["on:1"])
    }
}
