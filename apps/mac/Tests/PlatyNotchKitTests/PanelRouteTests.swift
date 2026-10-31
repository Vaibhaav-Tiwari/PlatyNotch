import Foundation
import PlatyNotchKit
import XCTest

final class PanelRouteTests: XCTestCase {
    private let tools: Set<String> = ["clipboard", "launch", "baskets", "time", "shelf", PanelTools.memory,
                                      PanelTools.chase, "games", "focus", "plugin:x"]

    func testOldDestinationsLandOnHome() {
        for t in ["now", "today", "home", "library"] {
            XCTAssertEqual(PanelRoute.legacy(tab: t, tools: []), PanelRoute(destination: .home), t)
        }
        XCTAssertEqual(PanelRoute.legacy(tab: "agents", tools: []), PanelRoute(destination: .agents))
    }

    func testToolTabsOpenInsideHome() {
        for t in ["memory", "games", "clipboard"] {
            XCTAssertEqual(PanelRoute.legacy(tab: t, tools: tools), PanelRoute(destination: .home, tool: t), t)
        }
    }

    /// Every tool the Library used to hold still has a way in through an old tab id.
    func testEveryOldLibraryToolIdOpensItsTool() {
        for t in tools where !t.hasPrefix("plugin:") && t != "time" && t != "focus" {
            XCTAssertEqual(PanelRoute.legacy(tab: t, tools: tools).tool, t, t)
            XCTAssertEqual(PanelRoute.legacy(tab: t, tools: tools).destination, .home, t)
        }
    }

    func testPluginTabOpensItsTool() {
        XCTAssertEqual(PanelRoute.legacy(tab: "x", tools: tools), PanelRoute(destination: .home, tool: "plugin:x"))
        XCTAssertEqual(PanelRoute.legacy(tab: "plugin:x", tools: tools), PanelRoute(destination: .home, tool: "plugin:x"))
        XCTAssertEqual(PanelTools.plugin("x"), "plugin:x")
    }

    func testUnknownTabIsHome() {
        XCTAssertEqual(PanelRoute.legacy(tab: "nonsense", tools: tools), PanelRoute(destination: .home))
        XCTAssertEqual(PanelRoute.legacy(tab: "", tools: tools), PanelRoute(destination: .home))
    }

    /// A tool whose widget is off is not offered: the link lands on Home instead of nothing.
    func testToolThatIsOffIsHome() {
        XCTAssertEqual(PanelRoute.legacy(tab: "clipboard", tools: []), PanelRoute(destination: .home))
    }

    func testBackFromToolIsHome() {
        XCTAssertEqual(PanelRoute(destination: .home, tool: "shelf").back(), PanelRoute(destination: .home))
        XCTAssertEqual(PanelRoute(destination: .agents).back(), PanelRoute(destination: .agents))
    }

    func testAgentsHiddenFallsBackToHome() {
        XCTAssertEqual(PanelRoute(destination: .agents).normalized(agentsVisible: false), PanelRoute(destination: .home))
        XCTAssertEqual(PanelRoute(destination: .agents).normalized(agentsVisible: true), PanelRoute(destination: .agents))
        XCTAssertEqual(PanelRoute(destination: .home, tool: "shelf").normalized(agentsVisible: false),
                       PanelRoute(destination: .home, tool: "shelf"))
        XCTAssertEqual(PanelRoute(destination: .agents, tool: "shelf").normalized(agentsVisible: true),
                       PanelRoute(destination: .agents), "a tool belongs to Home")
    }

    func testOnlyTwoDestinations() {
        XCTAssertEqual(PanelDestination.allCases, [.home, .agents])
        XCTAssertEqual(PanelDestination.shown(agentsVisible: true), [.home, .agents])
        XCTAssertEqual(PanelDestination.shown(agentsVisible: false), [.home])
    }

    /// Island: Focus is a mode of Timer; the old Time tool is the Timer tool.
    func testFocusAndTimeOpenTimer() {
        XCTAssertEqual(PanelRoute.legacy(tab: "focus", tools: []), PanelRoute(destination: .home, tool: "timer.focus"))
        XCTAssertEqual(PanelRoute.legacy(tab: "time", tools: []), PanelRoute(destination: .home, tool: "timer"))
        XCTAssertEqual(PanelTools.timer, "timer")
        XCTAssertEqual(PanelTools.timerFocus, "timer.focus")
        XCTAssertEqual(PanelTools.search, "search")
    }
}
