import Foundation

/// The optional sound when an agent needs you or an approval arrives (spec 8.5): off by
/// default, Platy's own chatter or a file the user picks, muted while the agent's terminal
/// is in front, played at a moderate volume (a sound is never an input, but it should not
/// startle anyone mid-click either).
public enum PlipPolicy {
    /// On or off (off when absent).
    public static let key = "agents.plipSound"
    /// "chatter" or "custom".
    public static let choiceKey = "agents.plipSound.choice"
    /// The chosen file as a bookmark (never copied into the app).
    public static let bookmarkKey = "agents.plipSound.bookmark"
    /// The chosen file's name, for Settings.
    public static let nameKey = "agents.plipSound.name"
    /// A chosen file may last at most this long.
    public static let maxDuration: TimeInterval = 5
    /// The playback volume, 0…1.
    public static let volume: Float = 0.45

    /// Whether the sound plays for `session` (nil: an approval whose session is unknown),
    /// once the sound is on (`PlipSettings.enabled`). Muted when the session's own terminal
    /// is frontmost; for a terminal that cannot be told (`pidAncestry`: tmux, unknown,
    /// absent), when any known terminal is frontmost.
    public static func shouldPlay(session: Session?, frontmostBundleID: String?,
                                  isRunning: (String) -> Bool) -> Bool {
        guard let front = frontmostBundleID else { return true }
        if let host = session?.hostBundleID, !host.isEmpty { return front != host }
        let target = TerminalApps.target(termProgram: session?.termProgram, isRunning: isRunning)
        switch target {
        case .appleTerminal: return front != TerminalApps.appleTerminalID
        case .iTerm: return front != TerminalApps.iTermID
        case .activate(let id):
            // VS Code and its forks report the same TERM_PROGRAM: any of them in front mutes.
            if TerminalApps.vscodeFamily.contains(id) { return !TerminalApps.vscodeFamily.contains(front) }
            return front != id
        case .pidAncestry: return !TerminalApps.knownTerminalIDs.contains(front)
        }
    }

    /// Settings › Notifications' "Quiet in focus sessions" row for `kind` (ruling m6): quiet
    /// while a focus session runs when that row says so. Approvals' row is locked to never,
    /// so an approval always sounds when the sound is on.
    public static func quietForFocus(_ kind: NotificationKind, policy: NotificationPolicy, focusActive: Bool) -> Bool {
        focusActive && policy[kind].quietDuringFocus
    }

    /// Whether a chosen file can be the sound (`duration`: nil when it does not open).
    public static func validate(duration: TimeInterval?) -> PlipValidation {
        guard let duration, duration > 0 else { return .unreadable }
        return duration <= maxDuration ? .ok : .tooLong(duration)
    }
}

/// The answer for a chosen sound file.
public enum PlipValidation: Equatable, Sendable {
    case ok
    case unreadable
    case tooLong(TimeInterval)

    /// What Settings says (nil when the file is fine).
    public var message: String? {
        switch self {
        case .ok: nil
        case .unreadable: "This file can't be played. Choose an audio file such as .wav, .aiff, .m4a or .mp3."
        case .tooLong(let s):
            "This sound lasts \(String(format: "%.1f", s)) seconds. Choose one of 5 seconds or less."
        }
    }
}

/// The sound settings, saved in `UserDefaults`.
public struct PlipSettings: Equatable, Sendable {
    public enum Choice: String, Sendable, CaseIterable {
        /// Platy chatter (bundled, original).
        case chatter
        /// A file the user chose.
        case custom
    }

    public var enabled: Bool
    public var choice: Choice
    public var bookmark: Data?
    public var customName: String?

    public init(enabled: Bool = false, choice: Choice = .chatter, bookmark: Data? = nil, customName: String? = nil) {
        self.enabled = enabled
        self.choice = choice
        self.bookmark = bookmark
        self.customName = customName
    }

    /// What plays: the chosen file only while one is saved, else Platy chatter.
    public var effectiveChoice: Choice {
        choice == .custom && bookmark != nil ? .custom : .chatter
    }

    public static func load(from d: UserDefaults) -> PlipSettings {
        PlipSettings(enabled: d.bool(forKey: PlipPolicy.key),
                     choice: d.string(forKey: PlipPolicy.choiceKey).flatMap(Choice.init(rawValue:)) ?? .chatter,
                     bookmark: d.data(forKey: PlipPolicy.bookmarkKey),
                     customName: d.string(forKey: PlipPolicy.nameKey))
    }

    public func save(to d: UserDefaults) {
        d.set(enabled, forKey: PlipPolicy.key)
        d.set(choice.rawValue, forKey: PlipPolicy.choiceKey)
        if let bookmark { d.set(bookmark, forKey: PlipPolicy.bookmarkKey) } else { d.removeObject(forKey: PlipPolicy.bookmarkKey) }
        if let customName { d.set(customName, forKey: PlipPolicy.nameKey) } else { d.removeObject(forKey: PlipPolicy.nameKey) }
    }
}
