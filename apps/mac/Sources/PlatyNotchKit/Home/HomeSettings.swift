import Foundation

/// Settings › Home: what fills Home's right column (spec 2.2, 7).
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

    /// The column to draw: the chosen one, or Up next while its widget is off.
    public func effectiveColumn(notesOn: Bool, mailOn: Bool) -> RightColumn {
        switch rightColumn {
        case .upNext: .upNext
        case .notes: notesOn ? .notes : .upNext
        case .mail: mailOn ? .mail : .upNext
        }
    }
}
