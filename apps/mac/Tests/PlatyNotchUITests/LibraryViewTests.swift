import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// XCTest brings in DeveloperToolsSupport, which has its own `LibraryItem` (Xcode's library).
private typealias LibraryItem = PlatyNotchKit.LibraryItem

/// A plugin-style widget with no data yet (a dimmed "Set up" tile).
@MainActor
private final class EmptyToolWidget: NotchWidget {
    let id = "fake.empty"
    let title = "Empty"
    let systemImage = "questionmark.square"
    let defaultEnabled = true
    var setUps = 0
    var hasContent: Bool { false }
    var setupAction: WidgetSetupAction { .run { [weak self] in self?.setUps += 1 } }
    func tileView() -> AnyView { AnyView(Text("tile")) }
}

/// Task 21: the open panel has three destinations; today's tabs and plugin tabs are
/// Library tools that open full-panel (spec 6.1, 6.6, 6.9, 6.10).
@MainActor
final class LibraryViewTests: DefaultsTestCase {
    private struct Rig {
        let store: AppStore
        let client: CoreClient
        let registry: WidgetRegistry
        let today: TodayServices
    }

    private func rig(started: Bool = true, extra: [any NotchWidget] = []) -> Rig {
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        let store = AppStore()
        BuiltInWidgets.register(in: registry, store: store, today: today, persist: false)
        for w in extra { registry.register(w) }
        if started {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnlib\(UUID().uuidString)")
            registry.start(context: WidgetContext(store: store, client: client,
                                                  config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                                  events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                                  surfaces: PanelSurfaces(registry: registry), openPanel: { _ in }))
        }
        return Rig(store: store, client: client, registry: registry, today: today)
    }

    private func panel(_ r: Rig, tabs: [PanelTab] = [], route: PanelRoute = PanelRoute(destination: .library),
                       agentsVisible: Bool = true) -> ExpandedPanel {
        var current = route
        return ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                             today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                             extraTabs: tabs, route: Binding(get: { current }, set: { current = $0 }),
                             onCollapse: {}, glanceDefaults: defaults(), agentsVisible: agentsVisible,
                             onDecide: { _, _ in }, onOpenTerminal: { _ in })
    }

    private let pluginTab = PanelTab(id: "fake.tab", title: "Fake", systemImage: "puzzlepiece") { Text("plugin") }

    func testNavHasThreeDestinations() {
        XCTAssertEqual(ExpandedPanel.destinations(agentsVisible: true), [.now, .agents, .library])
        XCTAssertEqual(ExpandedPanel.destinations(agentsVisible: false), [.now, .library])
        let p = panel(rig(), tabs: [pluginTab])
        XCTAssertEqual(p.destinations, [.now, .agents, .library], "plugin tabs never add a destination")
    }

    /// Spec 6.10: Focus, Memory and Games (with Platy Chase beside it) and plugin tabs all
    /// live in the Library, in its input order.
    func testEveryOldTabHasAHome() {
        let ids = panel(rig(), tabs: [pluginTab]).libraryTools.map(\.item.id)
        for id in [FocusWidget.widgetID, LibraryTools.memory, GamesWidget.widgetID, LibraryTools.chase,
                   LibraryTools.plugin("fake.tab")] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let games = ids.firstIndex(of: GamesWidget.widgetID)!
        XCTAssertEqual(ids[games + 1], LibraryTools.chase, "Platy Chase right after Games")
        XCTAssertEqual(ids.suffix(2), [LibraryTools.memory, LibraryTools.plugin("fake.tab")], "then Memory, then plugins")
        // Every tool opens to a view.
        for tool in panel(rig(), tabs: [pluginTab]).libraryTools {
            let host = NSHostingView(rootView: tool.view().frame(width: 528, height: 280))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0, tool.item.id)
        }
    }

    /// `expand(tab:)` keeps its signature and maps through `PanelRoute.legacy`.
    func testLegacyExpandRoutes() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry,
                                extraTabs: [pluginTab])
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .now))
        c.expand(tab: "memory")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: LibraryTools.memory))
        c.expand(tab: BuiltinTab.today)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .now))
        c.expand(tab: BuiltinTab.games)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: GamesWidget.widgetID))
        c.expand(tab: "fake.tab")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: "plugin:fake.tab"))
        c.expand(tab: "music")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: "music"))
        c.expand(tab: BuiltinTab.agents)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .agents))
    }

    func testDimmedTileOffersSetUp() {
        let empty = EmptyToolWidget()
        let r = rig(extra: [empty])
        let p = panel(r)
        let tool = p.libraryTools.first { $0.item.id == empty.id }
        XCTAssertEqual(tool?.item.isSetUp, false)
        XCTAssertEqual(LibraryTile.action(for: tool!.item), .setUp)
        let music = p.libraryTools.first { $0.item.id == "music" }!
        XCTAssertEqual(LibraryTile.action(for: music.item), .open)
        // "Set up" runs the widget's own setup (else its settings page).
        var opened: [String] = []
        var setUp: [String] = []
        let view = LibraryView(items: [tool!.item, music.item], tile: { _ in nil },
                               onOpen: { opened.append($0) }, onSetUp: { setUp.append($0) })
        view.activate(tool!.item)
        view.activate(music.item)
        XCTAssertEqual(setUp, [empty.id])
        XCTAssertEqual(opened, ["music"])
        p.setUp(empty.id)
        XCTAssertEqual(empty.setUps, 1)
        // The dimmed tile names its one action for VoiceOver.
        XCTAssertEqual(LibraryTile.accessibilityHint(for: tool!.item), "Set up Empty")
    }

    func testGridIsFourColumns() {
        XCTAssertEqual(LibraryView.columnCount, 4)
        XCTAssertEqual(LibraryView.tileWidth, (528 - 3 * 8) / 4)
        let items = (0..<12).map { LibraryItem(id: "t\($0)", title: "Tool \($0) with a very long name indeed",
                                               systemImage: "star", liveLine: String(repeating: "live ", count: 30),
                                               isSetUp: $0 % 3 != 0) }
        let host = NSHostingView(rootView: LibraryView(items: items, tile: { _ in nil }, onOpen: { _ in },
                                                       onSetUp: { _ in }).frame(width: 528, height: 288))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 528)
        // Twelve tools fit three rows without scrolling.
        XCTAssertLessThanOrEqual(LibraryView.gridHeight(count: 12), 288)
        XCTAssertFalse(LibraryView.scrolls(count: 12, height: 288))
        XCTAssertTrue(LibraryView.scrolls(count: 13, height: 288))
        let tile = NSHostingView(rootView: LibraryTile(item: items[1], custom: nil, onTap: {}).fixedSize())
        tile.layoutSubtreeIfNeeded()
        XCTAssertEqual(tile.fittingSize.width, LibraryView.tileWidth, accuracy: 0.5)
        XCTAssertEqual(tile.fittingSize.height, LibraryView.tileHeight, accuracy: 0.5, "long text never grows a tile")
    }

    func testDisabledWidgetsNotListed() {
        let r = rig()
        XCTAssertTrue(panel(r).libraryTools.contains { $0.item.id == "music" })
        r.registry.setEnabled("music", false)
        XCTAssertFalse(panel(r).libraryTools.contains { $0.item.id == "music" })
        r.registry.setEnabled(GamesWidget.widgetID, false)
        let ids = panel(r).libraryTools.map(\.item.id)
        XCTAssertFalse(ids.contains(GamesWidget.widgetID))
        XCTAssertFalse(ids.contains(LibraryTools.chase), "Platy Chase goes with Games")
        XCTAssertTrue(ids.contains(LibraryTools.memory))
    }

    /// Opening a tool notes it, so the grid puts it first next time; back returns to the grid.
    func testOpeningAToolPutsItFirst() {
        let r = rig()
        var route = PanelRoute(destination: .library)
        let p = ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                              today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                              extraTabs: [], route: Binding(get: { route }, set: { route = $0 }),
                              onCollapse: {}, glanceDefaults: defaults(), onDecide: { _, _ in }, onOpenTerminal: { _ in })
        p.openTool(LibraryTools.memory)
        XCTAssertEqual(route, PanelRoute(destination: .library, tool: LibraryTools.memory))
        XCTAssertEqual(p.sortedLibraryItems().first?.id, LibraryTools.memory)
        p.goBack()
        XCTAssertEqual(route, PanelRoute(destination: .library))
    }

    /// Glances and the quiet line open their tool directly.
    func testGlanceLinksOpenTheirTool() {
        XCTAssertEqual(ExpandedPanel.route(forTool: "loops"), PanelRoute(destination: .library, tool: "loops"))
        XCTAssertEqual(ExpandedPanel.route(forTool: FocusWidget.widgetID),
                       PanelRoute(destination: .library, tool: FocusWidget.widgetID))
    }

    /// The tool header: back chevron with its VoiceOver name, and the tool's title.
    func testToolHostHasABackChevron() {
        var backs = 0
        let host = ToolHost(title: "Memory", onBack: { backs += 1 }, content: AnyView(Text("x")))
        XCTAssertEqual(ToolHost.backLabel, "Back to Library")
        host.onBack()
        XCTAssertEqual(backs, 1)
        let v = NSHostingView(rootView: host.frame(width: 528, height: 288))
        v.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(v.fittingSize.width, 0)
    }

    /// The games tool fits the room a tool has below its header on a 38 pt notch.
    func testGamesFitAsATool() {
        XCTAssertNil(AppDelegate.checkGameViews())
        XCTAssertLessThanOrEqual(GameLayout.tabSize.height, ToolHost.contentHeight(available: 380 - 42 - 10))
    }
}
