import Foundation

/// The last titled track that played, kept for "Resume" when nothing plays (Island spec 3.5).
public struct LastPlayed: Codable, Equatable, Sendable {
    public let title: String
    public let artist: String?
    /// The app that played it (Resume sends play there).
    public let bundleID: String
    public let at: Date

    public static let key = "music.lastPlayed"

    public init(title: String, artist: String?, bundleID: String, at: Date) {
        self.title = title
        self.artist = artist
        self.bundleID = bundleID
        self.at = at
    }

    public static func load(from defaults: UserDefaults) -> LastPlayed? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(LastPlayed.self, from: $0) }
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    /// A new value only while a titled track plays from a known app (and not for the same
    /// track again, so nothing is written on every report); else `previous`.
    public static func update(_ info: NowPlayingInfo?, previous: LastPlayed?, now: Date) -> LastPlayed? {
        guard let info, info.isPlaying else { return previous }
        let title = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = info.appBundleIdentifier
        guard !title.isEmpty, !bundle.isEmpty else { return previous }
        if let previous, previous.title == title, previous.artist == info.artist, previous.bundleID == bundle {
            return previous
        }
        return LastPlayed(title: title, artist: info.artist, bundleID: bundle, at: now)
    }
}
