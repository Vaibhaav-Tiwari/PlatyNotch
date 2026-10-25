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
/// Off by default. Needs no permission. While enabled it samples the idle time adaptively
/// (`NudgeScheduler.nextSample`: when a pause going on now would reach 5 minutes, never
/// sooner than a minute), so a break of 5 minutes or more is seen wherever it falls; it
/// also wakes when a nudge falls due. During quiet hours it sleeps until they end, during
/// a focus session until the session ends. It pauses while the Mac sleeps, the screen is
/// locked or the session is switched away. After a wake, an unlock or a return from a
/// break the first card waits `resumeGrace`, and cards are `spacing` apart (also across a
/// relaunch), so several due nudges never come as a burst. Time asleep or locked ≥ 5 min
/// counts as a break, like idle. Clock and time-zone changes clamp saved times to now.
///
/// Nudges wait during a PlatyNotch focus session, a meeting (the `inMeeting` closure: the
/// app passes the meeting widget's state), full screen (`WidgetContext.panel`), quiet
/// hours and idle. A card nobody answers counts as dismissed for its interval (like Done);
/// only an explicit "Snooze 10 min" brings it back sooner.
///
/// Turned off, it does nothing: no timer, no observers, no idle reads. `disabled()` keeps
/// the water log.
@MainActor @Observable
final class WellbeingWidget: NotchWidget {
    static let widgetID = "wellbeing"
    static let peekID = "wellbeing.nudge"
    /// Timer slack for samples and due wakes (lets macOS coalesce wake-ups).
    static let tolerance: Duration = .seconds(10)

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
    /// No card before this (after a start, wake, unlock or a return from a break).
    @ObservationIgnored private(set) var resumeAt: Date?
    /// The last sample saw a break (idle ≥ `idleBreak`).
    @ObservationIgnored private var wasAway = false
    /// Idle reads so far (tests: a disabled widget reads none).
    @ObservationIgnored private(set) var idleReads = 0
    /// Progress writes so far (tests: only on change).
    @ObservationIgnored private(set) var saves = 0

    /// `watchSystem: false` (tests, smoke) skips the sleep / lock / clock observers.
    /// `inMeeting`: whether the user is in a meeting now (the app passes the meeting
    /// widget's state; this widget never asks for calendar access).
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

    /// The widget's clock (the tile's quiet-hours note and day).
    func now() -> Date { clock() }

    /// Observers held while running (tests).
    var observerCount: Int { observers.count }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard !running else { return }
        running = true
        self.context = context
        let now = clock()
        var p = progress.clamped(now: now)
        for kind in NudgeKind.allCases where p.lastDone[kind] == nil { p.lastDone[kind] = now }
        commit(p)
        var w = water
        w.prune(now: now)
        if w != water { water = w; saveWater() }
        resumeAt = now.addingTimeInterval(NudgeScheduler.resumeGrace)
        wasAway = false
        if watchSystem { watchSystemEvents() }
        reschedule(now: now)
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
        resumeAt = nil
        wasAway = false
        endCard()
        context = nil
    }

    /// Turned off: forget snoozes, the last card and when things were last done (turning
    /// it on again starts every interval afresh). The water log stays.
    func disabled() {
        commit(NudgeProgress())
    }

    // MARK: - Samples

    /// One wake-up: resolve a card that has run out, read the idle time and record breaks,
    /// show what is due, and sleep until the next sample or due time.
    func sample() {
        guard running, !paused, let context else { return }
        let now = clock()
        var p = progress
        if let n = nudge {
            if n.until > now {
                schedule(at: n.until.addingTimeInterval(0.5), tolerance: .milliseconds(100))
                return
            }
            // Nobody answered: dismissed for its interval (a looked-away eye break is done).
            nudge = nil
            p.lastDone[n.kind] = now
            p.snoozedUntil[n.kind] = nil
        }
        guard settings.anyOn else {
            commit(p)
            cancelTimer()
            return
        }
        if NudgeScheduler.isQuiet(settings, at: now, calendar: calendar) {
            // Nothing shows and intervals restart at the end: sleep until then.
            wasAway = false
            commit(p)
            let due = NudgeScheduler.nextWake(settings, lastDone: p.lastDone, snoozedUntil: p.snoozedUntil,
                                              now: now, calendar: calendar)
            schedule(at: atOrBeforeQuietEnd(due, now: now))
            return
        }
        idleReads += 1
        let idleSeconds = idle.secondsSinceLastInput()
        p.lastDone = NudgeScheduler.recordingBreaks(p.lastDone, settings: settings, now: now,
                                                    idleSeconds: idleSeconds, calendar: calendar)
        let away = idleSeconds >= NudgeScheduler.idleBreak
        if wasAway, !away { resumeAt = now.addingTimeInterval(NudgeScheduler.resumeGrace) }   // just sat down
        wasAway = away
        let focusEnd = focusSessionEnd(now)
        let c = NudgeContext(now: now, lastDone: p.lastDone, inFocusSession: focusEnd != nil,
                             inMeeting: inMeeting(), fullScreen: context.panel.fullScreen,
                             idleSeconds: idleSeconds, snoozedUntil: p.snoozedUntil)
        let floor = cardFloor(p)
        if floor.map({ now >= $0 }) ?? true, let kind = NudgeScheduler.due(settings, c, calendar: calendar) {
            p.lastCard = now
            commit(p)
            show(kind, now: now)
            return
        }
        commit(p)
        if let focusEnd {
            schedule(at: max(focusEnd, now.addingTimeInterval(NudgeScheduler.minimumWake)))
            return
        }
        let blocked = c.inMeeting || c.fullScreen || away
        var wake = blocked ? nil : NudgeScheduler.nextWake(settings, lastDone: p.lastDone, snoozedUntil: p.snoozedUntil,
                                                           now: now, notBefore: floor, calendar: calendar)
        if blocked || samplesBreaks {
            let s = NudgeScheduler.nextSample(now: now, idleSeconds: idleSeconds)
            wake = min(wake ?? s, s)
        }
        schedule(at: wake)
    }

    /// Whether idle breaks matter (they reset only stand and eyes).
    private var samplesBreaks: Bool { settings.interval(.stand) != nil || settings.interval(.eyes) != nil }

    /// No card before the spacing after the last one, or a resume grace.
    private func cardFloor(_ p: NudgeProgress) -> Date? {
        [p.lastCard.map { $0.addingTimeInterval(NudgeScheduler.spacing) }, resumeAt].compactMap { $0 }.max()
    }

    static func cardLength(_ kind: NudgeKind) -> TimeInterval {
        kind == .eyes ? NudgeScheduler.eyesBreak : NudgeScheduler.peekDuration
    }

    private func show(_ kind: NudgeKind, now: Date) {
        guard let context else { return }
        let length = Self.cardLength(kind)
        let n = Nudge(kind: kind, shownAt: now, until: now.addingTimeInterval(length))
        nudge = n
        guard context.peek(id: Self.peekID, until: n.until, as: .reminder) else {
            nudge = nil
            reschedule(now: now)
            return
        }
        schedule(at: n.until.addingTimeInterval(0.5), tolerance: .milliseconds(100))
    }

    // MARK: - Actions (card buttons, tile)

    func done(_ kind: NudgeKind) {
        var p = progress
        p.lastDone[kind] = clock()
        p.snoozedUntil[kind] = nil
        commit(p)
        finishCard(kind)
    }

    /// The only way a nudge comes back sooner than its interval.
    func snooze(_ kind: NudgeKind) {
        var p = progress
        p.snoozedUntil[kind] = clock().addingTimeInterval(NudgeScheduler.snooze)
        commit(p)
        finishCard(kind)
    }

    /// "+1 glass" (the water card or the tile): logs it and counts as the water nudge done.
    func addGlass() {
        water.add(at: clock())
        saveWater()
        done(.water)
    }

    func glassesToday() -> Int { water.count(on: clock(), calendar: calendar) }

    private func finishCard(_ kind: NudgeKind) {
        if nudge?.kind == kind { endCard() }
        if running, !paused, nudge == nil { reschedule(now: clock()) }
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
        var p = progress
        for kind in NudgeKind.allCases where next.interval(kind) != nil && before.minutes(kind) != next.minutes(kind) {
            p.lastDone[kind] = now
            p.snoozedUntil[kind] = nil
        }
        commit(p)
        if running, !paused, nudge == nil { reschedule(now: now) }
    }

    // MARK: - Scheduling

    /// After a change (start, a button, settings, a clock change), without reading the idle
    /// time: the next due time, or the next sample assuming the user is active now.
    private func reschedule(now: Date) {
        guard settings.anyOn else {
            cancelTimer()
            return
        }
        var wake = NudgeScheduler.nextWake(settings, lastDone: progress.lastDone, snoozedUntil: progress.snoozedUntil,
                                           now: now, notBefore: cardFloor(progress), calendar: calendar)
        if samplesBreaks, !NudgeScheduler.isQuiet(settings, at: now, calendar: calendar) {
            let s = NudgeScheduler.nextSample(now: now, idleSeconds: 0)
            wake = min(wake ?? s, s)
        }
        schedule(at: atOrBeforeQuietEnd(wake, now: now))
    }

    /// During quiet hours: wake no later than their end, so idle breaks after it are sampled
    /// even when the next nudge falls due well after (C7).
    private func atOrBeforeQuietEnd(_ wake: Date?, now: Date) -> Date? {
        guard settings.anyOn, NudgeScheduler.isQuiet(settings, at: now, calendar: calendar),
              let end = NudgeScheduler.quietEnd(after: now, settings, calendar: calendar) else { return wake }
        return min(wake ?? end, end)
    }

    private func schedule(at wake: Date?, tolerance: Duration = WellbeingWidget.tolerance) {
        task?.cancel()
        task = nil
        nextWake = wake
        guard let wake else { return }
        let delay = max(0, wake.timeIntervalSince(clock()))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: tolerance)
            guard !Task.isCancelled else { return }
            self?.sample()
        }
    }

    private func cancelTimer() { schedule(at: nil) }

    /// When the running PlatyNotch focus session ends (`FocusModel.untilKey`); nil when none.
    private func focusSessionEnd(_ now: Date) -> Date? {
        (defaults.object(forKey: FocusModel.untilKey) as? Date).flatMap { $0 > now ? $0 : nil }
    }

    // MARK: - Sleep, lock, session, clock

    func setPaused(_ reason: PauseReason, _ on: Bool) {
        guard running, pauseReasons.contains(reason) != on else { return }
        let wasPaused = paused
        if on { pauseReasons.insert(reason) } else { pauseReasons.remove(reason) }
        let now = clock()
        if !wasPaused, paused {
            pausedAt = now
            cancelTimer()
            endCard()   // never answered, never counted
        } else if wasPaused, !paused {
            let away = pausedAt.map { now.timeIntervalSince($0) } ?? 0
            pausedAt = nil
            var p = progress.clamped(now: now)
            p.lastDone = NudgeScheduler.recordingBreaks(p.lastDone, settings: settings, now: now,
                                                        idleSeconds: away, calendar: calendar)
            commit(p)
            resumeAt = now.addingTimeInterval(NudgeScheduler.resumeGrace)
            wasAway = false
            reschedule(now: now)
        }
    }

    /// The system clock or time zone changed: nothing saved may lie in the future.
    func clockChanged() {
        guard running else { return }
        let now = clock()
        commit(progress.clamped(now: now))
        if let r = resumeAt, r > now.addingTimeInterval(NudgeScheduler.resumeGrace) {
            resumeAt = now.addingTimeInterval(NudgeScheduler.resumeGrace)
        }
        // A card whose end is now further away than a whole card (the clock went back)
        // would stay up for that long: it ends, not counted as answered (C7).
        if let n = nudge, n.until > now.addingTimeInterval(Self.cardLength(n.kind)) { endCard() }
        if !paused, nudge == nil { reschedule(now: now) }
    }

    private func watchSystemEvents() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dn = DistributedNotificationCenter.default()
        let pairs: [(NotificationCenter, Notification.Name, PauseReason, Bool)] = [
            (ws, NSWorkspace.willSleepNotification, .sleep, true),
            (ws, NSWorkspace.didWakeNotification, .sleep, false),
            (ws, NSWorkspace.sessionDidResignActiveNotification, .session, true),
            (ws, NSWorkspace.sessionDidBecomeActiveNotification, .session, false),
            (dn, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (dn, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        for (center, name, reason, on) in pairs {
            let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setPaused(reason, on) }
            }
            observers.append((center, o))
        }
        for name in [Notification.Name.NSSystemClockDidChange, .NSSystemTimeZoneDidChange] {
            let o = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clockChanged() }
            }
            observers.append((NotificationCenter.default, o))
        }
    }

    // MARK: - Persistence

    /// Takes `next` and saves it, only when it differs.
    private func commit(_ next: NudgeProgress) {
        guard next != progress else { return }
        progress = next
        guard persist, let data = try? JSONEncoder().encode(next) else { return }
        defaults.set(data, forKey: NudgeProgress.key)
        saves += 1
    }

    private func saveWater() {
        guard persist, let data = try? JSONEncoder().encode(water) else { return }
        defaults.set(data, forKey: WaterLog.key)
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    // MARK: - Views

    func peekView(id: String) -> AnyView? {
        guard id == Self.peekID, let nudge else { return nil }
        return AnyView(NudgeCard(widget: self, nudge: nudge))
    }

    var kind: WidgetKind { [.glance, .tool] }

    /// Water tracking is on (a water interval is set).
    var hasContent: Bool { settings.water > 0 }

    /// "Water 5/8".
    func glanceView() -> AnyView? { AnyView(WellbeingGlance(widget: self)) }

    func tileView() -> AnyView { AnyView(WellbeingTile(widget: self)) }

    /// The Library tool: the water count and the nudges, centred.
    func toolView() -> AnyView { AnyView(ToolPage { WellbeingTile(widget: self) }) }

    func settingsView() -> AnyView? { AnyView(WellbeingSettings(widget: self)) }
}

/// Never reads anything (smoke runs).
final class ZeroIdleClock: IdleClock {
    func secondsSinceLastInput() -> TimeInterval { 0 }
}

/// The water glance: glasses today against the goal.
private struct WellbeingGlance: View {
    let widget: WellbeingWidget

    var body: some View {
        GlanceChip(systemImage: "drop.fill", value: "\(widget.glassesToday())/\(widget.settings.dailyWaterGoal)",
                   label: "Water")
    }
}
