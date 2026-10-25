import Foundation

/// The four glance slots in Now (spec 6.4), chosen by the user. A chosen glance with no
/// content (widget off, no data, plugin not loaded) is skipped without a gap and comes
/// back to the same slot; the others never move into its place for good (Ruling 6).
public struct GlanceSlots: Codable, Equatable, Sendable {
    public static let key = "now.glances"
    public static let limit = 4
    /// Claude and Codex usage: a glance the app itself provides (not a widget).
    public static let usageID = "agents.usage"

    public private(set) var ids: [String]

    public init(ids: [String] = []) {
        self.ids = Self.clean(ids)
    }

    /// The first four glance-capable widgets, in order.
    public static func defaults(glanceCapable: [String]) -> GlanceSlots {
        GlanceSlots(ids: glanceCapable)
    }

    /// De-duplicated (first wins), at most `limit`.
    public mutating func set(_ ids: [String]) {
        self.ids = Self.clean(ids)
    }

    /// The chosen ids that have content now, in slot order.
    public func shown(available: Set<String>) -> [String] {
        ids.filter(available.contains)
    }

    /// The saved choice, else (no key, or unreadable) the defaults.
    public static func load(from defaults: UserDefaults, glanceCapable: [String]) -> GlanceSlots {
        guard let data = defaults.data(forKey: key),
              let slots = try? JSONDecoder().decode(GlanceSlots.self, from: data) else {
            return Self.defaults(glanceCapable: glanceCapable)
        }
        return GlanceSlots(ids: slots.ids)
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func clean(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return Array(ids.filter { seen.insert($0).inserted }.prefix(limit))
    }
}
