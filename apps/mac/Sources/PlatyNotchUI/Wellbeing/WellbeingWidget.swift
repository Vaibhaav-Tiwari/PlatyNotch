import AppKit
import CoreGraphics
import Observation
import PlatyNotchKit
import SwiftUI

/// Seconds since the last keyboard, mouse or trackpad input. Tests use a fake; nothing
/// but `SystemIdleClock` reads the real idle state.
@MainActor
public protocol IdleClock: AnyObject {
    func secondsSinceLastInput() -> TimeInterval
}

/// The HID idle time from `CGEventSource`. Needs no permission (no TCC prompt, no
/// Accessibility or Input Monitoring): it reads a counter, not the events themselves.
public final class SystemIdleClock: IdleClock {
    /// `kCGAnyInputEventType` (~0): any keyboard, mouse or tablet event. `.null` (0) is
    /// not an input type: it reports seconds since boot-ish, so idle would never end.
    nonisolated static let anyInput = CGEventType(rawValue: ~0)!

    public init() {}

    public func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput)
    }
}

/// Water, stand and 20-20-20 eye-break nudges (`NudgeScheduler`): a card peeks below the
/// notch for 10 s (the eyes card for its 20 s ring) with Done / Snooze 10 min, or
/// "+1 glass" for water with today's count against the goal.
///
/// Off by default. Needs no permission. While enabled it sleeps until the next nudge is
/// due (one wake, at least a minute apart; a minute while the user is away so the break
/// ends when they return), reads the idle time once per wake, and pauses while the Mac
/// sleeps, the screen is locked or the session is switched away. After a wake or unlock
/// the first card waits `resumeGrace`, and cards are `spacing` apart, so several due
/// nudges never come as a burst. Time asleep or locked ≥ 5 min counts as a break, like idle.
///
/// Nudges wait during a PlatyNotch focus session, a meeting (only the meeting widget's
/// state, when it runs with calendar access: this widget never asks for calendar access),
/// full screen (`WidgetContext.panel`), quiet hours and idle. A card nobody answers counts
/// as a snooze, except the eyes card when there was no input during its ring (looked away).
///
/// Turned off, it does nothing: no timer, no observers, no idle reads. `disabled()` keeps
/// the water log.
@MainActor @Observable
final class WellbeingWidget: NotchWidget {
    static let widgetID = "wellbeing"
    static let peekID = "wellbeing.nudge"
    /// The eyes card counts as done when there was no input for this long at its end.
    static let lookedAway = NudgeScheduler.eyesBreak - 5

    /// The card on show (or held under an approval / the open panel until `until`).
    struct Nudge: Equatable {
        let kind: NudgeKind
        let shownAt: Date
        let until: Date
    }

    let id = WellbeingWidget.widgetID
    let title = "Wellbeing"
    let systemImage = "leaf"
    let defaultEnabled = false

    private(set) var settings: NudgeSettings
    private(set) var progress: NudgeProgress
    private(set) var water: WaterLog
    private(set) var nudge: Nudge?
    /// When the widget wakes next (nil: no timer).
    private(set) var nextWake: Date?
    /// Asleep, locked or switched away.
    var paused: Bool { !pauseReasons.isEmpty }
    private(set) var pauseReasons: Set<PauseReason> = []

    enum PauseReason: Hashable { case sleep, locked, session }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let idle: IdleClock
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored let calendar: Calendar
    @ObservationIgnored private let inMeeting: () -> Bool
    @ObservationIgnored private let watchSystem: Bool
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private(set) var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var pausedAt: Date?
    @ObservationIgnored private var lastCardAt: Date?
    /// Idle reads so far (tests: a disabled widget reads none).
    @ObservationIgnored private(set) var idleReads = 0

    /// `watchSystem: false` (tests, smoke) skips the sleep / lock observers.
    init(defaults: UserDefaults = .standard, persist: Bool = true, idle: IdleClock = SystemIdleClock(),
         clock: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent,
         inMeeting: @escaping () -> Bool = { false }, watchSystem: Bool = true) {
        self.defaults = defaults
        self.persist = persist
        self.idle = idle
        self.clock = clock
        self.calendar = calendar
        self.inMeeting = inMeeting
        self.watchSystem = watchSystem
        settings = Self.load(NudgeSettings.self, NudgeSettings.key, defaults) ?? NudgeSettings()
        progress = Self.load(NudgeProgress.self, NudgeProgress.key, defaults) ?? NudgeProgress()
        water = Self.load(WaterLog.self, WaterLog.key, defaults) ?? WaterLog()
    }

    /// A copy that saves nothing, observes nothing and never reads the idle time (smoke runs).
    static func inert() -> WellbeingWidget {
        WellbeingWidget(defaults: UserDefaults(suiteName: "dev.platynotch.inert-wellbeing") ?? .standard,
                        persist: false, idle: ZeroIdleClock(), watchSystem: false)
    }

    /// The meeting widget's "in a meeting", only while it runs (it then has calendar access
    /// when `inMeeting` is true; `MeetingWidget.current` requires it). Never asks for access.
    static func meetingSignal(registry: WidgetRegistry, meeting: MeetingWidget) -> () -> Bool {
        { [weak registry, weak meeting] in
            guard let registry, let meeting, registry.running.contains(MeetingWidget.widgetID) else { return false }
            return meeting.inMeeting
        }
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard !running else { return }
        running = true
        self.context = context
        let now = clock()
        seed(now: now)
        water.prune(now: now)
        save()
        if watchSystem { watchSleepAndLock() }
        schedule(now: now, notBefore: now.addingTimeInterval(NudgeScheduler.resumeGrace))
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        nextWake = nil
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        pauseReasons = []
        pausedAt = nil
        endCard()
        context = nil
    }

    /// Turned off: forget snoozes and when things were last done (turning it on again starts
    /// every interval afresh). The water log stays.
    func disabled() {
        progress = NudgeProgress()
        lastCardAt = nil
        save()
    }

    // MARK: - Checks

    /// One wake-up: resolve a card that has run out, record breaks, show what is due,
    /// sleep until the next one.
    func check() {
        guard running, !paused, let context else { return }
        let now = clock()
        if let n = nudge {
            if n.until > now {
                schedule(at: n.until.addingTimeInterval(0.5))
                return
            }
            unanswered(n, now: now)
        }
        guard settings.anyOn else {
            schedule(now: now)
            return
        }
        idleReads += 1
        let idleSeconds = idle.secondsSinceLastInput()
        progress.lastDone = NudgeScheduler.recordingBreaks(progress.lastDone, settings: settings, now: now,
                                                           idleSeconds: idleSeconds, calendar: calendar)
        let c = NudgeContext(now: now, lastDone: progress.lastDone, inFocusSession: focusSessionActive(now),
                             inMeeting: inMeeting(), fullScreen: context.panel.fullScreen,
                             idleSeconds: idleSeconds, snoozedUntil: progress.snoozedUntil)
        let spaced = lastCardAt.map { now >= $0.addingTimeInterval(NudgeScheduler.spacing) } ?? true
        if spaced, let kind = NudgeScheduler.due(settings, c, calendar: calendar) {
            save()
            show(kind, now: now)
            return
        }
        save()
        schedule(now: now, away: idleSeconds >= NudgeScheduler.idleBreak)
    }

    private func show(_ kind: NudgeKind, now: Date) {
        guard let context else { return }
        let length = kind == .eyes ? NudgeScheduler.eyesBreak : NudgeScheduler.peekDuration
        let n = Nudge(kind: kind, shownAt: now, until: now.addingTimeInterval(length))
        nudge = n
        lastCardAt = now
        guard context.peek(id: Self.peekID, until: n.until) else {
            nudge = nil
            schedule(now: now)
            return
        }
        schedule(at: n.until.addingTimeInterval(0.5))
    }

    /// Nobody answered: a snooze, except an eyes break taken (no input during the ring).
    private func unanswered(_ n: Nudge, now: Date) {
        nudge = nil
        if n.kind == .eyes {
            idleReads += 1
            if idle.secondsSinceLastInput() >= Self.lookedAway {
                markDone(.eyes, at: now)
                return
            }
        }
        progress.snoozedUntil[n.kind] = now.addingTimeInterval(NudgeScheduler.snooze)
        save()
    }

    // MARK: - Actions (card buttons, tile)

    func done(_ kind: NudgeKind) {
        markDone(kind, at: clock())
        finishCard(kind)
    }

    func snooze(_ kind: NudgeKind) {
        progress.snoozedUntil[kind] = clock().addingTimeInterval(NudgeScheduler.snooze)
        save()
        finishCard(kind)
    }

    /// "+1 glass" (the water card or the tile): logs it and counts as the water nudge done.
    func addGlass() {
        let now = clock()
        water.add(at: now)
        markDone(.water, at: now)
        finishCard(.water)
    }

    func glassesToday() -> Int { water.count(on: clock(), calendar: calendar) }

    private func markDone(_ kind: NudgeKind, at now: Date) {
        progress.lastDone[kind] = now
        progress.snoozedUntil[kind] = nil
        save()
    }

    private func finishCard(_ kind: NudgeKind) {
        if nudge?.kind == kind { endCard() }
        if running, !paused { schedule(now: clock()) }
    }

    private func endCard() {
        guard nudge != nil else { return }
        nudge = nil
        context?.endPeek(id: Self.peekID)
    }

    // MARK: - Settings

    func update(_ next: NudgeSettings) {
        guard next != settings else { return }
        let before = settings
        settings = next
        if persist, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: NudgeSettings.key) }
        // A nudge just turned on (or with a new interval) counts from now.
        let now = clock()
        for kind in NudgeKind.allCases where next.interval(kind) != nil && before.minutes(kind) != next.minutes(kind) {
            progress.lastDone[kind] = now
            progress.snoozedUntil[kind] = nil
        }
        save()
        if running, !paused { schedule(now: now) }
    }

    // MARK: - Scheduling

    private func seed(now: Date) {
        for kind in NudgeKind.allCases where progress.lastDone[kind] == nil { progress.lastDone[kind] = now }
    }

    /// Sleeps until `NudgeScheduler.nextWake` (none when every nudge is off). While the
    /// user is away, a minute at most, so the break follows their return.
    private func schedule(now: Date, notBefore: Date? = nil, away: Bool = false) {
        let spaced = lastCardAt.map { $0.addingTimeInterval(NudgeScheduler.spacing) }
        let floor = [notBefore, spaced].compactMap { $0 }.max()
        var wake = NudgeScheduler.nextWake(settings, lastDone: progress.lastDone, snoozedUntil: progress.snoozedUntil,
                                           now: now, notBefore: floor, calendar: calendar)
        if away, let w = wake { wake = min(w, now.addingTimeInterval(NudgeScheduler.minimumWake)) }
        guard let wake else {
            task?.cancel()
            task = nil
            nextWake = nil
            return
        }
        schedule(at: wake)
    }

    private func schedule(at wake: Date) {
        task?.cancel()
        nextWake = wake
        let delay = max(0, wake.timeIntervalSince(clock()))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.check()
        }
    }

    /// `FocusModel` publishes the end of a running focus session under `untilKey`.
    private func focusSessionActive(_ now: Date) -> Bool {
        (defaults.object(forKey: FocusModel.untilKey) as? Date).map { $0 > now } ?? false
    }

    // MARK: - Sleep, lock, session

    func setPaused(_ reason: PauseReason, _ on: Bool) {
        guard running, pauseReasons.contains(reason) != on else { return }
        let wasPaused = paused
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let now = clock()
        if !wasPaused, paused {
            pausedAt = now
            task?.cancel()
            task = nil
            nextWake = nil
            endCard()   // never answered, never counted
        } else if wasPaused, !paused {
            let away = pausedAt.map { now.timeIntervalSince($0) } ?? 0
            pausedAt = nil
            progress.lastDone = NudgeScheduler.recordingBreaks(progress.lastDone, settings: settings, now: now,
                                                               idleSeconds: away, calendar: calendar)
            save()
            schedule(now: now, notBefore: now.addingTimeInterval(NudgeScheduler.resumeGrace))
        }
    }

    private func watchSleepAndLock() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(NotificationCenter, Notification.Name, PauseReason, Bool)] = [
            (ws, NSWorkspace.willSleepNotification, .sleep, true),
            (ws, NSWorkspace.didWakeNotification, .sleep, false),
            (ws, NSWorkspace.sessionDidResignActiveNotification, .session, true),
            (ws, NSWorkspace.sessionDidBecomeActiveNotification, .session, false),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        for (center, name, reason, on) in pairs {
            let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(reason, on) }
            }
            observers.append((center, o))
        }
    }

    // MARK: - Persistence

    private func save() {
        guard persist else { return }
        let enc = JSONEncoder()
        if let data = try? enc.encode(progress) { defaults.set(data, forKey: NudgeProgress.key) }
        if let data = try? enc.encode(water) { defaults.set(data, forKey: WaterLog.key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: - Views

    func peekView(id: String) -> AnyView? {
        guard id == Self.peekID, let nudge else { return nil }
        return AnyView(NudgeCard(widget: self, nudge: nudge))
    }

    func tileView() -> AnyView { AnyView(WellbeingTile(widget: self)) }

    func settingsView() -> AnyView? { AnyView(WellbeingSettings(widget: self)) }
}

/// Never reads anything (smoke runs).
final class ZeroIdleClock: IdleClock {
    func secondsSinceLastInput() -> TimeInterval { 0 }
}
