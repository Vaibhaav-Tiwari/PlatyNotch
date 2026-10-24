import Foundation

/// The best score per game, kept in `UserDefaults.standard` (Task 10 ruling). Local only:
/// nothing is ever sent anywhere.
public struct HighScores: Codable, Equatable, Sendable {
    public static let key = "games.highScores"

    public private(set) var scores: [String: Int]

    public init(scores: [String: Int] = [:]) { self.scores = scores }

    /// Records `score` for `game`; true when it beats the best so far (a new best: Platy
    /// celebrates, Task 13). A tie or zero is not a new best.
    @discardableResult
    public mutating func record(game: String, score: Int) -> Bool {
        guard score > best(game) else { return false }
        scores[game] = score
        return true
    }

    public func best(_ game: String) -> Int { scores[game] ?? 0 }

    /// The saved scores; empty when none are saved or the value is damaged.
    public static func load(from defaults: UserDefaults) -> HighScores {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(HighScores.self, from: data) else { return HighScores() }
        return decoded
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
