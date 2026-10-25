import Foundation
import XCTest
@testable import PlatyNotchKit

/// XCTest brings in DeveloperToolsSupport, which has its own `LibraryItem` (Xcode's library).
private typealias LibraryItem = PlatyNotchKit.LibraryItem

/// Task 20: the Library's order (recently used first) and the open panel's routes, including
/// today's internal tab ids (spec 6.6, 6.10, 14).
final class LibraryModelTests: DefaultsTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func items(_ ids: [String]) -> [LibraryItem] {
        ids.map { LibraryItem(id: $0, title: $0.capitalized, systemImage: "square", liveLine: nil, isSetUp: true) }
    }

    func testRecentlyUsedFirst() {
        var recents = LibraryRecents()
        recents.noteOpened("clipboard", at: t0)
        recents.noteOpened("music", at: t0.addingTimeInterval(60))
        recents.noteOpened("clipboard", at: t0.addingTimeInterval(120))   // opened again: newest
        let sorted = LibraryOrder.sorted(items(["music", "time", "clipboard", "shelf"]), recents: recents)
        XCTAssertEqual(sorted.map(\.id), ["clipboard", "music", "time", "shelf"])
    }

    func testNeverUsedKeepOrder() {
        let input = ["music", "time", LibraryTools.chase, LibraryTools.memory, LibraryTools.plugin("pro.x")]
        XCTAssertEqual(LibraryOrder.sorted(items(input), recents: LibraryRecents()).map(\.id), input)
        var recents = LibraryRecents()
        recents.noteOpened(LibraryTools.memory, at: t0)
        recents.noteOpened("gone", at: t0.addingTimeInterval(5))   // a tool no longer listed is ignored
        XCTAssertEqual(LibraryOrder.sorted(items(input), recents: recents).map(\.id),
                       [LibraryTools.memory, "music", "time", LibraryTools.chase, LibraryTools.plugin("pro.x")])
    }

    func testRecentsPersist() {
        let d = defaults()
        XCTAssertEqual(LibraryRecents.load(from: d), LibraryRecents(), "nothing saved: empty")
        var recents = LibraryRecents()
        recents.noteOpened("music", at: t0)
        recents.noteOpened("games", at: t0.addingTimeInterval(1))
        recents.save(to: d)
        XCTAssertNotNil(d.data(forKey: LibraryRecents.key))
        let loaded = LibraryRecents.load(from: d)
        XCTAssertEqual(loaded, recents)
        XCTAssertEqual(LibraryOrder.sorted(items(["music", "games"]), recents: loaded).map(\.id), ["games", "music"])
        d.set(Data("not json".utf8), forKey: LibraryRecents.key)
        XCTAssertEqual(LibraryRecents.load(from: d), LibraryRecents(), "damaged: empty")
    }

    /// Spec 14: `today` → Now, `agents` → Agents, `focus`, `memory`, `games` → that tool.
    func testLegacyTabs() {
        let tools: Set<String> = ["focus", "games", "music", LibraryTools.memory]
        XCTAssertEqual(PanelRoute.legacy(tab: "today", tools: tools), PanelRoute(destination: .now))
        XCTAssertEqual(PanelRoute.legacy(tab: "now", tools: tools), PanelRoute(destination: .now))
        XCTAssertEqual(PanelRoute.legacy(tab: "agents", tools: tools), PanelRoute(destination: .agents))
        XCTAssertEqual(PanelRoute.legacy(tab: "library", tools: tools), PanelRoute(destination: .library))
        XCTAssertEqual(PanelRoute.legacy(tab: "focus", tools: tools), PanelRoute(destination: .library, tool: "focus"))
        XCTAssertEqual(PanelRoute.legacy(tab: "memory", tools: tools), PanelRoute(destination: .library, tool: "memory"))
        XCTAssertEqual(PanelRoute.legacy(tab: "games", tools: tools), PanelRoute(destination: .library, tool: "games"))
        // Even when the tool is not listed right now (its widget is off), the old tab ids keep their home.
        XCTAssertEqual(PanelRoute.legacy(tab: "focus", tools: []), PanelRoute(destination: .library, tool: "focus"))
        XCTAssertEqual(PanelRoute.legacy(tab: "music", tools: tools), PanelRoute(destination: .library, tool: "music"))
        XCTAssertEqual(PanelRoute.legacy(tab: LibraryTools.chase, tools: [LibraryTools.chase]),
                       PanelRoute(destination: .library, tool: LibraryTools.chase))
    }

    func testPluginTabRoutes() {
        XCTAssertEqual(LibraryTools.plugin("pro.usage"), "plugin:pro.usage")
        let tools: Set<String> = [LibraryTools.plugin("pro.usage")]
        XCTAssertEqual(PanelRoute.legacy(tab: "pro.usage", tools: tools),
                       PanelRoute(destination: .library, tool: "plugin:pro.usage"), "a plugin's own tab id")
        XCTAssertEqual(PanelRoute.legacy(tab: "plugin:pro.usage", tools: tools),
                       PanelRoute(destination: .library, tool: "plugin:pro.usage"))
    }

    func testUnknownTabGoesToNow() {
        XCTAssertEqual(PanelRoute.legacy(tab: "nonsense", tools: ["music"]), PanelRoute(destination: .now))
        XCTAssertEqual(PanelRoute.legacy(tab: "", tools: ["music"]), PanelRoute(destination: .now))
        XCTAssertEqual(PanelRoute.legacy(tab: "plugin:missing", tools: []), PanelRoute(destination: .now))
    }

    func testHiddenAgentsRouteFallsBack() {
        let agents = PanelRoute(destination: .agents)
        XCTAssertEqual(agents.normalized(agentsVisible: true), agents)
        XCTAssertEqual(agents.normalized(agentsVisible: false), PanelRoute(destination: .now))
        // A tool only belongs to the Library.
        XCTAssertEqual(PanelRoute(destination: .now, tool: "music").normalized(agentsVisible: true),
                       PanelRoute(destination: .now))
        let tool = PanelRoute(destination: .library, tool: "music")
        XCTAssertEqual(tool.normalized(agentsVisible: false), tool)
    }

    func testBackReturnsToGrid() {
        XCTAssertEqual(PanelRoute(destination: .library, tool: "memory").back(), PanelRoute(destination: .library))
        XCTAssertEqual(PanelRoute(destination: .library).back(), PanelRoute(destination: .library))
        XCTAssertEqual(PanelRoute(destination: .now).back(), PanelRoute(destination: .now))
        XCTAssertEqual(PanelRoute(destination: .agents).back(), PanelRoute(destination: .agents))
    }
}
