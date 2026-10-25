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
        decode(defaults.data(forKey: key)) ?? Self.defaults(glanceCapable: glanceCapable)
    }

    /// The saved choice; with none yet, the defaults, saved at once so they never change
    /// as widgets come and go (the slots never backfill, Ruling 6). `glanceCapable` is every
    /// registered glance in registry order, on or off.
    public static func resolve(from defaults: UserDefaults, glanceCapable: [String]) -> GlanceSlots {
        if defaults.object(forKey: key) != nil { return load(from: defaults, glanceCapable: glanceCapable) }
        let slots = Self.defaults(glanceCapable: glanceCapable)
        slots.save(to: defaults)
        return slots
    }

    /// Decodes saved slots (nil for missing or unreadable data).
    public static func decode(_ data: Data?) -> GlanceSlots? {
        guard let data, let slots = try? JSONDecoder().decode(GlanceSlots.self, from: data) else { return nil }
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
