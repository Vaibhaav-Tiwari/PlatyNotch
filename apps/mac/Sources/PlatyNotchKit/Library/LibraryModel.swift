import Foundation

/// One tile in the Library (spec 6.6): a tool's icon, name and one live line ("2 timers",
/// "5 items"). `isSetUp == false` shows it dimmed with one "Set up" action.
public struct LibraryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    public let liveLine: String?
    public let isSetUp: Bool
    /// The dimmed tile's action when it is not "Set up" (e.g. "Allow", which brings up
    /// macOS's own prompt).
    public let setupTitle: String?
    /// Something is going on (playing, focusing, a timer running): the line is tinted and a
    /// dot shows.
    public let isLive: Bool

    public init(id: String, title: String, systemImage: String, liveLine: String?, isSetUp: Bool,
                setupTitle: String? = nil, isLive: Bool = false) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.liveLine = liveLine
        self.isSetUp = isSetUp
        self.setupTitle = setupTitle
        self.isLive = isLive
    }
}

/// When each Library tool was last opened (spec 6.6: recently used first).
public struct LibraryRecents: Codable, Equatable, Sendable {
    public static let key = "library.recents"

    /// Tool id → last opened.
    private var opened: [String: Date]

    public init() { opened = [:] }

    public mutating func noteOpened(_ id: String, at date: Date) {
        opened[id] = date
    }

    /// When `id` was last opened; nil when never.
    public func lastOpened(_ id: String) -> Date? { opened[id] }

    /// The saved recents; empty when none are saved or the value is damaged.
    public static func load(from defaults: UserDefaults) -> LibraryRecents {
        guard let data = defaults.data(forKey: key) else { return LibraryRecents() }
        return decode(data)
    }

    /// The recents in `data`; empty when it is damaged.
    public static func decode(_ data: Data) -> LibraryRecents {
        (try? JSONDecoder().decode(LibraryRecents.self, from: data)) ?? LibraryRecents()
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

/// The Library's order: tools used most recently first, then the never-used ones in their
/// input order (widget tools in the user's order, Platy Chase after Games, Memory, plugin tabs).
public enum LibraryOrder {
    public static func sorted(_ items: [LibraryItem], recents: LibraryRecents) -> [LibraryItem] {
        let used: [(Int, LibraryItem, Date)] = items.enumerated().compactMap { pair in
            recents.lastOpened(pair.element.id).map { (pair.offset, pair.element, $0) }
        }
        let recent: [LibraryItem] = used.sorted { a, b in
            a.2 != b.2 ? a.2 > b.2 : a.0 < b.0
        }.map(\.1)
        let never: [LibraryItem] = items.filter { recents.lastOpened($0.id) == nil }
        return recent + never
    }
}

/// Library tool ids that are not a widget's own id.
public enum LibraryTools {
    /// Memory search and graph (today's Memory tab).
    public static let memory = "memory"
    /// Platy Chase keeps its own entry beside Games (spec 6.10).
    public static let chase = "games.chase"
    /// A plugin `PanelTab` as a tool: "plugin:<tab id>".
    public static func plugin(_ tabID: String) -> String { pluginPrefix + tabID }

    static let pluginPrefix = "plugin:"
}
