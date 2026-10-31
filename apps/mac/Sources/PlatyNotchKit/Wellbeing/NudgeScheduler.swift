import Foundation

/// A wellbeing nudge: drink water, stand up, or rest the eyes (20-20-20).
public enum NudgeKind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
    case water, stand, eyes

    /// When several are due, the first of these shows.
    public static let priority: [NudgeKind] = [.eyes, .stand, .water]
}

/// Settings › Widgets › Wellbeing. Intervals are minutes (0 = off; water is off for new users); quiet hours are whole
/// hours of the local day, `quietStart` up to (not including) `quietEnd`, spanning
/// midnight when start > end, none when start == end.
public struct NudgeSettings: Codable, Equatable, Sendable {
    /// UserDefaults key (JSON).
    public static let key = "wellbeing.settings"
    /// The longest interval Settings offers.
    public static let maxMinutes = 240
    /// Today's water interval: what an existing user keeps (`QuietNotchMigration`) and what a
    /// saved value without a `water` key means.
    public static let legacyWaterMinutes = 60

    public var water: Int
    public var stand: Int
    public var eyes: Int
    public var quietStart: Int
    public var quietEnd: Int
    public var dailyWaterGoal: Int

    public init(water: Int = 0, stand: Int = 50, eyes: Int = 20, quietStart: Int = 22, quietEnd: Int = 8,
                dailyWaterGoal: Int = 8) {
        self.water = water
        self.stand = stand
        self.eyes = eyes
        self.quietStart = quietStart
        self.quietEnd = quietEnd
        self.dailyWaterGoal = dailyWaterGoal
        clamp()
    }

    /// Missing keys take their defaults (settings saved by an older build still load).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NudgeSettings()
        water = try c.decodeIfPresent(Int.self, forKey: .water) ?? Self.legacyWaterMinutes
        stand = try c.decodeIfPresent(Int.self, forKey: .stand) ?? d.stand
        eyes = try c.decodeIfPresent(Int.self, forKey: .eyes) ?? d.eyes
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? d.quietStart
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? d.quietEnd
        dailyWaterGoal = try c.decodeIfPresent(Int.self, forKey: .dailyWaterGoal) ?? d.dailyWaterGoal
        clamp()
    }

    private mutating func clamp() {
        water = min(max(water, 0), Self.maxMinutes)
        stand = min(max(stand, 0), Self.maxMinutes)
        eyes = min(max(eyes, 0), Self.maxMinutes)
        quietStart = min(max(quietStart, 0), 23)
        quietEnd = min(max(quietEnd, 0), 23)
        dailyWaterGoal = min(max(dailyWaterGoal, 1), 30)
    }

    public func minutes(_ kind: NudgeKind) -> Int {
        switch kind {
        case .water: water
        case .stand: stand
        case .eyes: eyes
        }
    }

    public mutating func setMinutes(_ value: Int, for kind: NudgeKind) {
        switch kind {
        case .water: water = value
        case .stand: stand = value
        case .eyes: eyes = value
        }
        clamp()
    }

    /// The interval in seconds; nil when that nudge is off.
    public func interval(_ kind: NudgeKind) -> TimeInterval? {
        let m = minutes(kind)
        return m > 0 ? TimeInterval(m) * 60 : nil
    }

    /// Whether any nudge is on (otherwise the widget sleeps with no timer at all).
    public var anyOn: Bool { NudgeKind.allCases.contains { interval($0) != nil } }

    public var hasQuietHours: Bool { quietStart != quietEnd }
}

/// What `NudgeScheduler.due` decides from. `lastDone` and `snoozedUntil` are per kind; a
/// kind with no `lastDone` is never due (the widget seeds it when the nudge turns on).
public struct NudgeContext: Sendable {
    public let now: Date
    public let lastDone: [NudgeKind: Date]
    /// A PlatyNotch focus session is running.
    public let inFocusSession: Bool
    /// In a calendar meeting (the meeting widget's state, when it runs with calendar access).
    public let inMeeting: Bool
    /// A full-screen app covers a panel's display.
    public let fullScreen: Bool
    /// Seconds since the last keyboard, mouse or trackpad input.
    public let idleSeconds: TimeInterval
    /// "Snooze 10 min" (or an unanswered card): not before this.
    public let snoozedUntil: [NudgeKind: Date]

    public init(now: Date, lastDone: [NudgeKind: Date], inFocusSession: Bool = false, inMeeting: Bool = false,
                fullScreen: Bool = false, idleSeconds: TimeInterval = 0, snoozedUntil: [NudgeKind: Date] = [:]) {
        self.now = now
        self.lastDone = lastDone
        self.inFocusSession = inFocusSession
        self.inMeeting = inMeeting
        self.fullScreen = fullScreen
        self.idleSeconds = idleSeconds
        self.snoozedUntil = snoozedUntil
    }
}

/// When a wellbeing nudge is due. Pure: the clock, idle time and calendar come in.
///
/// Nothing is due during a focus session, a meeting, full screen, quiet hours, or while the
/// user is idle (≥ `idleBreak`). An idle stretch that long counts as a break: it resets
/// stand and eyes, not water (`recordingBreaks`). Intervals also restart when quiet hours
/// end, so mornings do not open with every nudge at once. Eyes beats stand beats water.
public enum NudgeScheduler {
    /// Idle this long is a break (and nothing nudges meanwhile).
    public static let idleBreak: TimeInterval = 300
    /// No wake-up sooner than this after the last (the collapsed-panel budget).
    public static let minimumWake: TimeInterval = 60
    /// "Snooze 10 min", and what an unanswered card counts as.
    public static let snooze: TimeInterval = 600
    /// How long a water or stand card stays.
    public static let peekDuration: TimeInterval = 10
    /// The eyes card stays for its 20-second ring ("look 20 feet away for 20 seconds").
    public static let eyesBreak: TimeInterval = 20
    /// The least time between two cards (no bursts when several are due).
    public static let spacing: TimeInterval = 300
    /// After a wake or unlock, the first card waits this long.
    public static let resumeGrace: TimeInterval = 120

    /// The nudge to show now, if any.
    public static func due(_ s: NudgeSettings, _ c: NudgeContext, calendar: Calendar) -> NudgeKind? {
        if c.inFocusSession || c.inMeeting || c.fullScreen || c.idleSeconds >= idleBreak { return nil }
        if isQuiet(s, at: c.now, calendar: calendar) { return nil }
        return NudgeKind.priority.first { kind in
            dueDate(kind, s, lastDone: c.lastDone, snoozedUntil: c.snoozedUntil).map { $0 <= c.now } ?? false
        }
    }

    /// When `kind` falls due (ignoring quiet hours and context); nil when off or never seeded.
    public static func dueDate(_ kind: NudgeKind, _ s: NudgeSettings, lastDone: [NudgeKind: Date],
                               snoozedUntil: [NudgeKind: Date]) -> Date? {
        guard let interval = s.interval(kind), let last = lastDone[kind] else { return nil }
        let due = last.addingTimeInterval(interval)
        guard let snoozed = snoozedUntil[kind] else { return due }
        return max(due, snoozed)
    }

    /// Whether `date` is inside quiet hours (by the hour of `calendar`'s local day).
    public static func isQuiet(_ s: NudgeSettings, at date: Date, calendar: Calendar) -> Bool {
        guard s.hasQuietHours else { return false }
        let hour = calendar.component(.hour, from: date)
        if s.quietStart < s.quietEnd { return hour >= s.quietStart && hour < s.quietEnd }
        return hour >= s.quietStart || hour < s.quietEnd
    }

    /// The first end of quiet hours after `date` (`quietEnd`:00 local; when DST skips that
    /// hour, the first moment after the gap). Nil without quiet hours.
    public static func quietEnd(after date: Date, _ s: NudgeSettings, calendar: Calendar) -> Date? {
        guard s.hasQuietHours else { return nil }
        return calendar.nextDate(after: date, matching: DateComponents(hour: s.quietEnd, minute: 0, second: 0),
                                 matchingPolicy: .nextTime)
    }

    /// The most recent end of quiet hours at or before `date`.
    static func lastQuietEnd(atOrBefore date: Date, _ s: NudgeSettings, calendar: Calendar) -> Date? {
        guard s.hasQuietHours else { return nil }
        let match = DateComponents(hour: s.quietEnd, minute: 0, second: 0)
        if calendar.date(date, matchesComponents: match) { return date }
        return calendar.nextDate(after: date, matching: match, matchingPolicy: .nextTime, direction: .backward)
    }

    /// `lastDone` with the breaks taken since: idle (or asleep, locked) for `idleSeconds`
    /// ≥ `idleBreak` resets stand and eyes to `now` (water keeps its time); every kind last
    /// done before the latest end of quiet hours restarts from it.
    public static func recordingBreaks(_ lastDone: [NudgeKind: Date], settings s: NudgeSettings, now: Date,
                                       idleSeconds: TimeInterval, calendar: Calendar) -> [NudgeKind: Date] {
        var out = lastDone
        if let end = lastQuietEnd(atOrBefore: now, s, calendar: calendar), !isQuiet(s, at: now, calendar: calendar) {
            for (kind, last) in out where last < end { out[kind] = end }
        }
        if idleSeconds >= idleBreak {
            for kind in [NudgeKind.stand, .eyes] where out[kind] != nil { out[kind] = now }
        }
        return out
    }

    /// The next idle sample while the widget is on: when a pause going on since the last
    /// input would reach `idleBreak`, never sooner than `minimumWake`. So any pause of
    /// `idleBreak + minimumWake` or more is seen, wherever it falls between due times.
    public static func nextSample(now: Date, idleSeconds: TimeInterval) -> Date {
        now.addingTimeInterval(max(minimumWake, idleBreak - max(0, idleSeconds)))
    }

    /// The single wake-up for the next check: the earliest due time of the nudges that are
    /// on (moved to the end of quiet hours when it falls inside them), never before
    /// `notBefore` and never sooner than `minimumWake` from `now`. Nil when every nudge is
    /// off (no timer at all).
    public static func nextWake(_ s: NudgeSettings, lastDone: [NudgeKind: Date], snoozedUntil: [NudgeKind: Date],
                                now: Date, notBefore: Date? = nil, calendar: Calendar) -> Date? {
        let dates = NudgeKind.allCases.compactMap { dueDate($0, s, lastDone: lastDone, snoozedUntil: snoozedUntil) }
        guard var wake = dates.min() else { return nil }
        wake = max(wake, notBefore ?? now, now.addingTimeInterval(minimumWake))
        if isQuiet(s, at: wake, calendar: calendar), let end = quietEnd(after: wake, s, calendar: calendar) {
            wake = end
        }
        return wake
    }
}

/// When each nudge was last done, how long it is snoozed, and when the last card showed
/// (the spacing between cards survives a relaunch). UserDefaults, JSON.
public struct NudgeProgress: Codable, Equatable, Sendable {
    public static let key = "wellbeing.progress"

    public var lastDone: [NudgeKind: Date]
    public var snoozedUntil: [NudgeKind: Date]
    public var lastCard: Date?

    public init(lastDone: [NudgeKind: Date] = [:], snoozedUntil: [NudgeKind: Date] = [:], lastCard: Date? = nil) {
        self.lastDone = lastDone
        self.snoozedUntil = snoozedUntil
        self.lastCard = lastCard
    }

    /// After the clock was set back: nothing done (or shown) later than `now`, and no
    /// snooze longer than one from now.
    public func clamped(now: Date) -> NudgeProgress {
        let limit = now.addingTimeInterval(NudgeScheduler.snooze)
        return NudgeProgress(lastDone: lastDone.mapValues { min($0, now) },
                             snoozedUntil: snoozedUntil.mapValues { min($0, limit) },
                             lastCard: lastCard.map { min($0, now) })
    }
}
