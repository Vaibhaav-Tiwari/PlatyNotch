import Foundation

/// Where the open panel is: a destination and, inside Home, an open feature (a tool).
public struct PanelRoute: Equatable, Sendable {
    public var destination: PanelDestination
    /// The feature open full-panel inside Home (Clipboard, Baskets, Time, Memory, a plugin
    /// tab…); nil shows Home itself. Only meaningful on Home.
    public var tool: String?

    public init(destination: PanelDestination, tool: String? = nil) {
        self.destination = destination
        self.tool = tool
    }

    /// Today's internal tab ids (`WidgetContext.openPanel(tab:)`, `NotchController.expand(tab:)`,
    /// spec 7): `now`, `today`, `home`, `library` → Home; `agents` → Agents; `focus`, `memory`,
    /// `games`, a tool in `tools` (or a plugin tab id whose `plugin:<id>` is in `tools`) → Home
    /// with that tool open; anything else → Home. A tool whose widget is off is not in `tools`,
    /// so its link lands on Home instead of a blank view.
    public static func legacy(tab: String, tools: Set<String>) -> PanelRoute {
        switch tab {
        case "now", "today", "home", "library": return PanelRoute(destination: .home)
        case "agents": return PanelRoute(destination: .agents)
        case "focus", PanelTools.memory, "games": return PanelRoute(destination: .home, tool: tab)
        default: break
        }
        if tools.contains(tab) { return PanelRoute(destination: .home, tool: tab) }
        let plugin = PanelTools.plugin(tab)
        if tools.contains(plugin) { return PanelRoute(destination: .home, tool: plugin) }
        return PanelRoute(destination: .home)
    }

    /// The route the panel can show: Agents falls back to Home while it is hidden, and a tool
    /// belongs only to Home.
    public func normalized(agentsVisible: Bool) -> PanelRoute {
        switch destination {
        case .agents: return agentsVisible ? PanelRoute(destination: .agents) : PanelRoute(destination: .home)
        case .home: return self
        }
    }

    /// The back chevron: an open tool returns to plain Home; elsewhere nothing changes.
    public func back() -> PanelRoute {
        destination == .home ? PanelRoute(destination: .home) : self
    }
}

/// Tool ids that are not a widget's own id: features reached inside Home.
public enum PanelTools {
    /// Memory search and graph.
    public static let memory = "memory"
    /// Platy Chase keeps its own entry beside Games.
    public static let chase = "games.chase"
    /// A plugin `PanelTab` as a tool: "plugin:<tab id>".
    public static func plugin(_ tabID: String) -> String { pluginPrefix + tabID }

    static let pluginPrefix = "plugin:"
}
