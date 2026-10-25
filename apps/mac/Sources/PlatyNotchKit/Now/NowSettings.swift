import Foundation

/// Settings › Now beyond the glances (`GlanceSlots`): whether the hero steps through the
/// live items (‹ › and swipes) or shows only the most important one.
public struct NowSettings: Codable, Equatable, Sendable {
    public static let key = "now.settings"

    public var heroCycling: Bool

    public init(heroCycling: Bool = true) {
        self.heroCycling = heroCycling
    }

    /// The saved settings; the defaults when none are saved or the value is damaged.
    public static func load(from defaults: UserDefaults) -> NowSettings {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(NowSettings.self, from: data) else { return NowSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
