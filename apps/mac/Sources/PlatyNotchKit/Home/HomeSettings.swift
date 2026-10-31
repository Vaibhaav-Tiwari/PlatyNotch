import Foundation

/// Quiet Notch's Settings › Home choice of right column. Island has no right column; the
/// value still decodes, and the Island migration reads it once (a Mail column user gets
/// Mail in the dock).
public struct HomeSettings: Codable, Equatable, Sendable {
    /// What the right column shows. Notes and Mail are offered only while their widget is on.
    public enum RightColumn: String, Codable, CaseIterable, Sendable { case upNext, notes, mail }

    public static let key = "home.settings"

    public var rightColumn: RightColumn

    public init(rightColumn: RightColumn = .upNext) {
        self.rightColumn = rightColumn
    }

    /// The saved settings; the defaults when none are saved or the value is damaged.
    public static func load(from defaults: UserDefaults) -> HomeSettings {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(HomeSettings.self, from: data) else { return HomeSettings() }
        return saved
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
