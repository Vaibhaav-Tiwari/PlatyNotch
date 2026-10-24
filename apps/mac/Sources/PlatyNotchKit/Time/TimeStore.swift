import Foundation

/// Something the Time widget must act on: a timer reached zero or an alarm is due.
public struct TimeEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case timer(UUID)
        case alarm(UUID)
    }

    public let kind: Kind
    public let dueAt: Date
    /// Ring in the notch. False when the app learns of it late (it was quit, or the Mac
    /// slept past `TimeState.ringGrace`): the backup notification has already shown.
    public let ring: Bool

    public init(kind: Kind, dueAt: Date, ring: Bool) {
        self.kind = kind
        self.dueAt = dueAt
        self.ring = ring
    }
}

/// A system notification scheduled as a backup, so a timer or alarm still fires when the
/// app is not running. Scheduled `delay` after the in-app ring: while the app runs, it
/// rings first and cancels the backup, so the two never show together.
public struct TimeBackup: Equatable, Sendable {
    public static let delay: TimeInterval = 3

    public enum Trigger: Equatable, Sendable {
        /// Seconds from now (timers: `UNTimeIntervalNotificationTrigger`).
        case interval(TimeInterval)
        /// A wall-clock date (alarms: `UNCalendarNotificationTrigger`).
        case calendar(DateComponents)
    }

    /// The notification id, e.g. "time.timer.<uuid>".
    public let id: String
    public let title: String
    public let body: String
    public let fireAt: Date
    public let trigger: Trigger

    public init(id: String, title: String, body: String, fireAt: Date, trigger: Trigger) {
        self.id = id
        self.title = title
        self.body = body
        self.fireAt = fireAt
        self.trigger = trigger
    }

    /// What to (re)schedule and which ids to cancel to go from `old` to `new`. A backup
    /// with the same id, fire date and text is left alone.
    public static func diff(old: [TimeBackup], new: [TimeBackup]) -> (schedule: [TimeBackup], cancel: [String]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let schedule = new.filter { b in
            guard let o = before[b.id] else { return true }
            return o.fireAt != b.fireAt || o.title != b.title || o.body != b.body
        }
        let keep = Set(new.map(\.id))
        return (schedule, old.map(\.id).filter { !keep.contains($0) })
    }

    public static func timerID(_ id: UUID) -> String { "time.timer.\(id.uuidString)" }
    public static func alarmID(_ id: UUID) -> String { "time.alarm.\(id.uuidString)" }
}

/// Everything the Time widget keeps: timers, the stopwatch, alarms, world clocks, and how
/// far the scheduler has looked (`lastCheck`). Pure value; `TimeStore` persists it.
public struct TimeState: Codable, Equatable, Sendable {
    public static let maxTimers = 10
    public static let maxAlarms = 20
    public static let maxClocks = 12
    /// Something found due later than this (the Mac slept, the app was quit) does not ring.
    public static let ringGrace: TimeInterval = 5 * 60
    /// A clock set back by more than this restarts the scheduler's window at the new time;
    /// smaller steps (time sync) never fire anything twice.
    public static let clockStepBack: TimeInterval = 60
    public static let pomodoro = (work: TimeInterval(25 * 60), rest: TimeInterval(5 * 60))

    public var timers: [CountdownTimer]
    public var stopwatch: Stopwatch
    public var alarms: [Alarm]
    public var clocks: [WorldClock]
    /// Everything due up to here has been handled.
    public var lastCheck: Date?

    public init(timers: [CountdownTimer] = [], stopwatch: Stopwatch = Stopwatch(), alarms: [Alarm] = [],
                clocks: [WorldClock] = [], lastCheck: Date? = nil) {
        self.timers = timers
        self.stopwatch = stopwatch
        self.alarms = alarms
        self.clocks = clocks
        self.lastCheck = lastCheck
    }

    /// Handles everything due in (`lastCheck`, `now`]: finished timers (a pomodoro starts
    /// its break at the moment it ended) and due alarms (a once alarm turns itself off).
    /// Each fires once. `announce: false` (launch) never rings.
    public mutating func advance(to now: Date, calendar: Calendar, announce: Bool) -> [TimeEvent] {
        var from = lastCheck ?? now
        if now < from - Self.clockStepBack { from = now }
        defer { lastCheck = max(from, now) }
        guard now > from else { return [] }
        func ring(_ due: Date) -> Bool { announce && now.timeIntervalSince(due) <= Self.ringGrace }

        var events: [TimeEvent] = []
        var i = 0
        while i < timers.count {
            if let end = timers[i].endsAt, end > from, end <= now {
                events.append(TimeEvent(kind: .timer(timers[i].id), dueAt: end, ring: ring(end)))
                if let next = timers[i].then {
                    timers[i].then = nil
                    if timers.count < Self.maxTimers {
                        timers.append(CountdownTimer(label: next.label, duration: next.duration, startedAt: end))
                    }
                }
            }
            i += 1
        }
        for j in alarms.indices {
            guard let due = alarms[j].nextRing(after: from, calendar: calendar), due <= now else { continue }
            events.append(TimeEvent(kind: .alarm(alarms[j].id), dueAt: due, ring: ring(due)))
            alarms[j].markFired()
        }
        return events
    }

    /// The backup notifications that should be pending at `now`: each running timer (at its
    /// end) and each alarm's next ring, `TimeBackup.delay` later.
    public func backups(now: Date, calendar: Calendar) -> [TimeBackup] {
        var out: [TimeBackup] = []
        for t in timers {
            guard let end = t.endsAt, end > now else { continue }
            let at = end.addingTimeInterval(TimeBackup.delay)
            out.append(TimeBackup(id: TimeBackup.timerID(t.id), title: t.label.isEmpty ? "Timer" : t.label,
                                  body: "\(DurationParser.describe(t.duration)) timer is done.",
                                  fireAt: at, trigger: .interval(at.timeIntervalSince(now))))
        }
        for a in alarms {
            guard let next = a.nextRing(after: now, calendar: calendar) else { continue }
            let at = next.addingTimeInterval(TimeBackup.delay)
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
            out.append(TimeBackup(id: TimeBackup.alarmID(a.id), title: a.label.isEmpty ? "Alarm" : a.label,
                                  body: "Alarm · \(a.timeText)", fireAt: at, trigger: .calendar(comps)))
        }
        return out
    }

    /// When something next becomes due after `now` (nil: nothing scheduled).
    public func nextWake(after now: Date, calendar: Calendar) -> Date? {
        let ends = timers.compactMap(\.endsAt).filter { $0 > now }
        let rings = alarms.compactMap { $0.nextRing(after: now, calendar: calendar) }
        return (ends + rings).min()
    }

    // MARK: - Changes the views make

    /// A 25-minute "Pomodoro" timer that starts a 5-minute break when it ends.
    @discardableResult
    public mutating func startPomodoro(at date: Date) -> Bool {
        guard timers.count < Self.maxTimers else { return false }
        var t = CountdownTimer(label: "Pomodoro", duration: Self.pomodoro.work,
                               then: .init(label: "Break", duration: Self.pomodoro.rest))
        t.start(at: date)
        timers.append(t)
        return true
    }

    public mutating func snoozeAlarm(_ id: UUID, at date: Date) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].snooze(at: date)
    }

    public mutating func setAlarmEnabled(_ id: UUID, _ on: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[i].setEnabled(on)
    }
}

/// `TimeState` as JSON in `UserDefaults` under "time.v1" (the app's own domain), with the
/// limits: up to 10 timers, 20 alarms and 12 clocks.
public final class TimeStore {
    public static let key = "time.v1"
    public static let maxTimers = TimeState.maxTimers
    public static let maxAlarms = TimeState.maxAlarms
    public static let maxClocks = TimeState.maxClocks

    public private(set) var state: TimeState
    private let defaults: UserDefaults
    private let persist: Bool

    /// `persist: false` reads the saved state but never writes it (smoke runs).
    public init(defaults: UserDefaults, persist: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(TimeState.self, from: $0) }
            ?? TimeState()
    }

    /// Changes the state and saves it when it changed.
    @discardableResult
    public func update<T>(_ change: (inout TimeState) -> T) -> T {
        var next = state
        let result = change(&next)
        if next != state {
            state = next
            save()
        }
        return result
    }

    @discardableResult
    public func addTimer(_ timer: CountdownTimer) -> Bool {
        update { s in
            guard s.timers.count < Self.maxTimers else { return false }
            s.timers.append(timer)
            return true
        }
    }

    @discardableResult
    public func addAlarm(_ alarm: Alarm) -> Bool {
        update { s in
            guard s.alarms.count < Self.maxAlarms else { return false }
            s.alarms.append(alarm)
            return true
        }
    }

    @discardableResult
    public func addClock(_ clock: WorldClock) -> Bool {
        update { s in
            guard s.clocks.count < Self.maxClocks else { return false }
            s.clocks.append(clock)
            return true
        }
    }

    public func save() {
        guard persist, let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
