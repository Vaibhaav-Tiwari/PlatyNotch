import Foundation

/// Where the open panel is: a destination and, in the Library, an open tool.
public struct PanelRoute: Equatable, Sendable {
    public var destination: PanelDestination
    /// The Library tool open full-panel; nil shows the grid. Only meaningful in the Library.
    public var tool: String?

    public init(destination: PanelDestination, tool: String? = nil) {
        self.destination = destination
        self.tool = tool
    }

    /// Today's internal tab ids (`WidgetContext.openPanel(tab:)`, `NotchController.expand(tab:)`,
    /// spec 14): `now` and `today` → Now, `agents` → Agents, `library` → the grid, `focus`,
    /// `memory`, `games` → that Library tool, a tool in `tools` (or a plugin tab id whose
    /// `plugin:<id>` is in `tools`) → that tool; anything else → Now.
    public static func legacy(tab: String, tools: Set<String>) -> PanelRoute {
        switch tab {
        case "now", "today": return PanelRoute(destination: .now)
        case "agents": return PanelRoute(destination: .agents)
        case "library": return PanelRoute(destination: .library)
        case "focus", LibraryTools.memory, "games": return PanelRoute(destination: .library, tool: tab)
        default: break
        }
        if tools.contains(tab) { return PanelRoute(destination: .library, tool: tab) }
        let plugin = LibraryTools.plugin(tab)
        if tools.contains(plugin) { return PanelRoute(destination: .library, tool: plugin) }
        return PanelRoute(destination: .now)
    }

    /// The route the panel can show: Agents falls back to Now while it is hidden, and a tool
    /// belongs only to the Library.
    public func normalized(agentsVisible: Bool) -> PanelRoute {
        switch destination {
        case .agents: return agentsVisible ? PanelRoute(destination: .agents) : PanelRoute(destination: .now)
        case .now: return PanelRoute(destination: .now)
        case .library: return self
        }
    }

    /// The back chevron: an open tool returns to the Library grid; elsewhere nothing changes.
    public func back() -> PanelRoute {
        destination == .library ? PanelRoute(destination: .library) : self
    }
}
