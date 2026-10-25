import Foundation

/// What a live activity draws in the compact pill.
public enum LiveGlyph: Equatable, Sendable {
    /// An SF Symbol name.
    case symbol(String)
    /// Bouncing bars (music playing).
    case musicBars
    /// One dot per session state (for plugins; the built-in agent dots are `PillDots`).
    case agentDots([SessionState])
    /// A progress ring, 0...1.
    case ring(progress: Double)
    /// A short text, e.g. "72%".
    case text(String)
}

/// Which ear of the compact pill holds live activities (the other holds the agent dots).
/// `AppearanceSettings.liveSide` (Plan 3 stored it as `appearance.liveSide`); right by default.
public enum LiveSide: String, Codable, CaseIterable, Sendable {
    case left, right
}

/// The pill's color for an activity (the view maps it to a real color).
public enum LiveTint: Equatable, Sendable {
    case neutral, accent, warning, critical
}

/// Something going on right now that may own the compact pill (a running timer, music,
/// a focus session). Widgets publish these; `LiveArbiter` picks what shows.
public struct LiveActivity: Identifiable, Equatable, Sendable {
    /// Unique across widgets, e.g. "timer:3".
    public let id: String
    public let widgetID: String
    /// See `LivePriority`.
    public let priority: Int
    public let glyph: LiveGlyph
    /// Short text after the glyph, e.g. "72%".
    public let trailing: String?
    public let tint: LiveTint
    /// After this the activity is ignored.
    public let expiresAt: Date?
    /// When set, the pill shows a live countdown to this date (m:ss) instead of `trailing`,
    /// updating once a second only while it is shown.
    public let countdownTo: Date?
    /// When set (and `countdownTo` is not), the pill shows the time since this date
    /// (m:ss, a running stopwatch), updating like `countdownTo`.
    public let countUpFrom: Date?
    /// What VoiceOver says for it in the pill, e.g. "Music playing".
    public let accessibilityLabel: String?
    /// The hero's title in Now, e.g. a meeting's name or "Music". Nil: the accessibility
    /// label, else the widget id (`PriorityModel`).
    public let title: String?
    /// The hero's second line, e.g. a meeting's start time.
    public let subtitle: String?
    /// When it began: ties between equal ranks go to whichever started first (spec 6.3).
    public let startedAt: Date?

    public init(id: String, widgetID: String, priority: Int, glyph: LiveGlyph, trailing: String? = nil,
                tint: LiveTint = .neutral, expiresAt: Date? = nil, countdownTo: Date? = nil,
                countUpFrom: Date? = nil, accessibilityLabel: String? = nil, title: String? = nil,
                subtitle: String? = nil, startedAt: Date? = nil) {
        self.id = id
        self.widgetID = widgetID
        self.priority = priority
        self.glyph = glyph
        self.trailing = trailing
        self.tint = tint
        self.expiresAt = expiresAt
        self.countdownTo = countdownTo
        self.countUpFrom = countUpFrom
        self.accessibilityLabel = accessibilityLabel
        self.title = title
        self.subtitle = subtitle
        self.startedAt = startedAt
    }

    /// Ambient activities show only when nothing else is live and never keep the pill up
    /// in Minimal mode.
    public var isAmbient: Bool { priority <= LivePriority.ambient }

    public func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

/// Who wins the pill. Higher wins; ties keep the order the activities were given in.
/// `LiveRank(activity:now:)` maps these numbers (and any plugin's) into the spec 6.3 bands.
public enum LivePriority {
    /// Pending approval (drawn by the pill itself as the badge, never a widget).
    public static let approval = 100
    public static let alarmRinging = 95
    public static let timerFinished = 90
    /// The band of an agent that needs you. The built-in agents item comes from
    /// `AgentsLive` (sessions), not from an activity; a plugin may still publish this.
    public static let agentBlocked = 80
    /// A meeting starting within `meetingSoonWindow`.
    public static let meetingSoon = 75
    public static let focusSession = 60
    public static let timerRunning = 55
    public static let stopwatch = 50
    public static let musicPlaying = 40
    /// The band of working agents (see `agentBlocked`).
    public static let agentActive = 30
    /// A file action in progress (the shelf's convert, zip, rename).
    public static let fileAction = 26
    public static let download = 25
    /// A panel feature left running: the camera mirror on, Platy Chase in play (minor).
    public static let panelActivity = 23
    public static let keepAwake = 22
    /// Battery at or below 10%.
    public static let batteryLow = 20
    public static let shelfItems = 10
    /// Charging (ambient, C9: shows only when nothing else is live, never keeps Minimal up).
    public static let batteryCharging = 5
    /// At or below this an activity is ambient (shelf, battery above 10%, weather).
    public static let ambient = 10

    /// Matches the meeting reminders at 10 / 5 / 1 minutes.
    public static let meetingSoonWindow: TimeInterval = 10 * 60
}
