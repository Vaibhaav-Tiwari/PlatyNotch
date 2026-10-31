import Foundation

/// What the Now Playing card shows when nothing plays (Island spec 3.5): a caption,
/// Resume and up to two recents when something played before, Platy's greeting, and a
/// hint when nothing ever played.
public struct MusicEmptyState: Equatable, Sendable {
    public let caption: String
    public let resume: String?
    public let recents: [String]
    public let greeting: String
    public let hint: String?

    public static let maxRecents = 2

    public init(caption: String, resume: String?, recents: [String], greeting: String, hint: String?) {
        self.caption = caption
        self.resume = resume
        self.recents = recents
        self.greeting = greeting
        self.hint = hint
    }

    /// Recents show only beside Resume (they are the same app's).
    public static func make(last: LastPlayed?, recents: [String], hour: Int) -> MusicEmptyState {
        MusicEmptyState(caption: "Nothing playing",
                        resume: last.map { "Resume \"\($0.title)\"" },
                        recents: last == nil ? [] : Array(recents.prefix(maxRecents)),
                        greeting: greeting(hour: hour),
                        hint: last == nil ? "Play something and it shows here." : nil)
    }

    /// 05–12 morning, 12–17 afternoon, 17–22 evening, else late night.
    public static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: "Fresh morning. Platy's on it."
        case 12..<17: "Quiet afternoon. Platy's on it."
        case 17..<22: "Quiet evening. Platy's on it."
        default: "Late night. Platy's on it."
        }
    }
}
