import Foundation

/// What the closed pill shows first after approvals and a session needing you (Island
/// spec 7): music, timer, working agents; or working agents, timer, music.
public enum PillOrder: String, Codable, Sendable {
    case musicFirst, agentsFirst
}

/// When the panel shows the Agents tab (Island spec 6): once hooks are set up (today's
/// `AgentsVisibility`), or always.
public enum AgentsTabRule: String, Codable, Sendable {
    case whenHooksSetUp, always
}

/// The Island choices a preset makes beyond widgets and the notch mode.
public struct IslandPrefs: Codable, Equatable, Sendable {
    public static let key = "island.prefs"

    /// The dock folds into one Search slot, "All tools" (Minimal).
    public var dockFolded = false
    public var pillOrder: PillOrder = .musicFirst
    public var agentsTab: AgentsTabRule = .whenHooksSetUp

    public init(dockFolded: Bool = false, pillOrder: PillOrder = .musicFirst,
                agentsTab: AgentsTabRule = .whenHooksSetUp) {
        self.dockFolded = dockFolded
        self.pillOrder = pillOrder
        self.agentsTab = agentsTab
    }

    /// The saved choices; the defaults when none are saved or the value is damaged.
    public static func load(from defaults: UserDefaults) -> IslandPrefs {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(IslandPrefs.self, from: data) else { return IslandPrefs() }
        return saved
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// What a preset makes Home, the dock, the pill and the Agents tab look like (Island spec 6).
public struct IslandLayout: Equatable, Sendable {
    public let dock: DockLayout
    public let prefs: IslandPrefs

    public init(dock: DockLayout, prefs: IslandPrefs) {
        self.dock = dock
        self.prefs = prefs
    }

    /// Timer, Note, Remind, Clipboard, Shelf, then `sixth`, then Search.
    static func dock(with sixth: DockTool) -> DockLayout {
        DockLayout(slots: [DockTool.timer, .note, .remind, .clipboard, .shelf, sixth, .search].map(DockSlot.core))
    }
}

extension SetupPreset {
    /// Everyday: the dock with Games, music first. Developer: Memory for Games, agents first,
    /// Agents always shown. Minimal: Everyday's dock folded into Search.
    public var layout: IslandLayout {
        switch self {
        case .everyday:
            IslandLayout(dock: IslandLayout.dock(with: .games), prefs: IslandPrefs())
        case .developer:
            IslandLayout(dock: IslandLayout.dock(with: .memory),
                         prefs: IslandPrefs(pillOrder: .agentsFirst, agentsTab: .always))
        case .minimal:
            IslandLayout(dock: IslandLayout.dock(with: .games), prefs: IslandPrefs(dockFolded: true))
        }
    }
}
