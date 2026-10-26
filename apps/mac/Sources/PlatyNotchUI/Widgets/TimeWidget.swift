import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Timers (several at once, plus a pomodoro), a stopwatch with laps, alarms and world
/// clocks. State is `TimeStore` ("time.v1" in `UserDefaults.standard`), so everything
/// survives a relaunch.
///
/// Firing: one wake-up task sleeps until the next due time (no polling; at most every
/// `maxSleep` while something is scheduled) and `TimeState.advance` decides what is due.
/// Each running timer and each alarm's next ring also has a system notification as a
/// backup (`TimeBackup`, 3 s after the in-app ring, cancelled when the app rings), so they
/// fire when the app is quit or the Mac restarted. On launch nothing rings: what came due
/// meanwhile is shown as finished (a once alarm is off), and its delivered backup is kept.
///
/// Ringing (`WidgetContext.ring`): alarms ring until Stop or Snooze (9 min), also during a
/// focus session; finished timers ring for `timerRingTime`, then stay as a "Done" notice
/// (the tile and the pill) for `noticeTime`; a timer finishing during a focus session does
/// not ring or play a sound (notice only). The sound loops for at most `soundLimit`.
/// `PanelSurfaces.rings` is what rings (games pause on it, Task 10).
/// Starts a countdown from outside the Time tile: `platynotch://timer/start` after its
/// confirm peek (R7), and later the voice assistant's `start_timer` (T10).
@MainActor
protocol TimerStarter: AnyObject {
    /// Starts a timer of `duration` seconds (more than 0, at most 24 h), labelled `label`
    /// or its length. False when it is invalid, the timers are full or the widget is off.
    @discardableResult
    func startTimer(duration: TimeInterval, label: String?) -> Bool
}

@MainActor @Observable
final class TimeWidget: NotchWidget, TimerStarter {
    static let widgetID = "time"
    static let timerRingTime: TimeInterval = 30
    static let soundLimit: TimeInterval = 60
    static let noticeTime: TimeInterval = 10 * 60
    static let maxSleep: TimeInterval = 300
    /// Set once notification permission was asked for (first timer or alarm).
    static let askedKey = "time.notificationsAsked"

    enum Section: String, CaseIterable, Identifiable {
        case timers = "Timers", stopwatch = "Stopwatch", alarms = "Alarms", clocks = "Clocks"
        var id: String { rawValue }
    }

    /// Something of ours ringing; `id` is also its `TimeBackup` id.
    struct Ring: Equatable, Identifiable {
        enum Kind: Equatable { case timer(UUID), alarm(UUID) }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        var isAlarm: Bool { if case .alarm = kind { true } else { false } }
    }

    let id = TimeWidget.widgetID
    let title = "Time"
    let systemImage = "timer"
    let defaultEnabled = true

    private(set) var state: TimeState
    private(set) var ringing: [Ring] = []
    /// Timers that finished recently and are not dismissed: timer id → when it ended.
    private(set) var finished: [UUID: Date] = [:]
    /// Advanced on every wake-up so `liveActivities` follows the clock.
    private(set) var now: Date
    /// The tile's section.
    var section: Section = .timers

    @ObservationIgnored private let store: TimeStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let sound: RingSound
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let calendar: () -> Calendar
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private var wakeTask: Task<Void, Never>?
    @ObservationIgnored private var soundTask: Task<Void, Never>?
    @ObservationIgnored private var ringTimeouts: [String: Task<Void, Never>] = [:]
    /// Backups Notification Center accepted (an id is recorded only after `schedule` succeeded).
    @ObservationIgnored private var scheduled: [String: TimeBackup] = [:]
    /// Backup changes run one after another (each awaits the one before).
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var authTask: Task<Void, Never>?
    /// Kept after `stop` so `disabled()` can cancel the backups.
    @ObservationIgnored private var notifier: Notifier?
    /// The sound looping now (nil when silent).
    @ObservationIgnored private var playing: TimeSound?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var watchGeneration = 0

    init(defaults: UserDefaults = .standard, persist: Bool = true, sound: RingSound? = nil,
         clock: @escaping () -> Date = Date.init, calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.defaults = defaults
        store = TimeStore(defaults: defaults, persist: persist)
        self.sound = sound ?? SystemRingSound()
        self.clock = clock
        self.calendar = calendar
        state = store.state
        now = clock()
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        self.context = context
        notifier = context.notify
        let t = clock()
        now = t
        // Launch: what came due meanwhile (the backup showed it) is shown, never rung; a once
        // alarm that came due turns off. After `disabled()` `lastCheck` is nil, so turning the
        // widget back on handles nothing from the time it was off (alarms keep their next ring).
        let events = store.update { $0.advance(to: t, calendar: calendar(), announce: false) }
        for e in events { handle(e) }
        state = store.state
        syncBackups(forgetting: events)
        scheduleWake()
        observeSystem()
        watchRings()
    }

    /// Stops all work, including a ringing sound (the panel may show a generic Stop card).
    /// Backup notifications stay scheduled: `stop` also runs when the app quits, and they
    /// are what fires then. Turning the widget off also calls `disabled()`, which cancels them.
    func stop() {
        watchGeneration += 1   // our own stopRinging below is not a user's Stop
        wakeTask?.cancel()
        wakeTask = nil
        soundTask?.cancel()
        soundTask = nil
        for t in ringTimeouts.values { t.cancel() }
        ringTimeouts = [:]
        silence()
        for r in ringing { context?.stopRinging(id: r.id) }
        ringing = []
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        store.save()
        context = nil
    }

    /// Turned off by the user (after `stop`): a disabled widget does no work, so every
    /// backup notification is cancelled, and the scheduler forgets where it was: on re-enable
    /// `start` reschedules from the saved state and nothing that came due while off fires
    /// or turns a once alarm off (it keeps its next occurrence).
    func disabled() {
        var ids = Set(scheduled.keys)
        ids.formUnion(store.state.timers.map { TimeBackup.timerID($0.id) })
        ids.formUnion(store.state.alarms.map { TimeBackup.alarmID($0.id) })
        store.update { $0.lastCheck = nil }
        finished = [:]
        authTask?.cancel()
        enqueue { w in
            for id in ids.sorted() { w.notifier?.cancel(id: id) }
            w.scheduled = [:]
        }
    }

    // MARK: - Scheduler

    /// Handles what is due now, then sleeps until the next thing.
    func tick() {
        guard context != nil else { return }
        let t = clock()
        now = t
        let events = store.update { $0.advance(to: t, calendar: calendar(), announce: true) }
        for e in events { handle(e) }
        finished = finished.filter { t.timeIntervalSince($0.value) < Self.noticeTime }
        state = store.state
        syncBackups(forgetting: events)
        scheduleWake()
    }

    private func scheduleWake() {
        wakeTask?.cancel()
        wakeTask = nil
        guard context != nil else { return }
        let t = clock()
        var next = state.nextWake(after: t, calendar: calendar())
        if let expiry = finished.values.map({ $0.addingTimeInterval(Self.noticeTime) }).filter({ $0 > t }).min() {
            next = min(next ?? expiry, expiry)
        }
        guard let next else { return }   // nothing scheduled: no wake-ups at all
        let delay = min(max(0, next.timeIntervalSince(t)) + 0.05, Self.maxSleep)
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    /// Wake from sleep and clock or time zone changes re-check at once.
    private func observeSystem() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let nc = NotificationCenter.default
        let pairs: [(NotificationCenter, Notification.Name)] = [
            (ws, NSWorkspace.didWakeNotification), (nc, .NSSystemClockDidChange), (nc, .NSSystemTimeZoneDidChange),
        ]
        for (center, name) in pairs {
            let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            observers.append((center, o))
        }
    }

    private func handle(_ e: TimeEvent) {
        switch e.kind {
        case .timer(let id):
            finished[id] = e.dueAt
            guard e.ring, let timer = storedTimer(id) else { return }
            // Settings › Notifications decides whether it opens the notch (spec 6.3: alarms and
            // timers are not quiet during focus sessions by default); it always rings.
            let title = timer.label.isEmpty ? "Timer" : timer.label
            ring(Ring(id: TimeBackup.timerID(id), kind: .timer(id), title: title,
                      subtitle: "\(DurationParser.describe(timer.duration)) timer is done"), sound: .chime)
        case .alarm(let id):
            guard e.ring, let alarm = store.state.alarms.first(where: { $0.id == id }) else { return }
            ring(Ring(id: TimeBackup.alarmID(id), kind: .alarm(id), title: alarm.label.isEmpty ? "Alarm" : alarm.label,
                      subtitle: "Alarm · \(Self.timeText(hour: alarm.hour, minute: alarm.minute))"), sound: .alarm)
        }
    }

    private func storedTimer(_ timer: UUID) -> CountdownTimer? { store.state.timers.first { $0.id == timer } }

    // MARK: - Backups (system notifications)

    /// Schedules / cancels backups to match the state (queued; see `applyBackups`). Events
    /// found late (`ring == false`) had their backup delivered already: it is forgotten,
    /// never cancelled (which would also remove it from Notification Center).
    private func syncBackups(forgetting events: [TimeEvent] = []) {
        guard context != nil else { return }
        for e in events where !e.ring {
            switch e.kind {
            case .timer(let id): scheduled[TimeBackup.timerID(id)] = nil
            case .alarm(let id): scheduled[TimeBackup.alarmID(id)] = nil
            }
        }
        enqueue { await $0.applyBackups() }
    }

    /// Runs `op` after every backup change queued before it.
    private func enqueue(_ op: @escaping @MainActor (TimeWidget) async -> Void) {
        let previous = syncTask
        syncTask = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await op(self)
        }
    }

    /// Diffs the wanted backups (from the state as it is now) against those Notification
    /// Center accepted. A refused add (no permission yet) stays unrecorded, so the next
    /// sync, e.g. right after permission is granted, adds it again.
    private func applyBackups() async {
        guard context != nil, let notify = notifier else { return }
        let new = store.state.backups(now: clock(), calendar: calendar())
        let diff = TimeBackup.diff(old: Array(scheduled.values), new: new)
        for id in diff.cancel {
            notify.cancel(id: id)
            scheduled[id] = nil
        }
        for b in diff.schedule {
            scheduled[b.id] = nil
            let ok: Bool = switch b.trigger {
            case .interval: await notify.schedule(id: b.id, title: b.title, body: b.body, at: b.fireAt)
            case .calendar(let comps): await notify.schedule(id: b.id, title: b.title, body: b.body, matching: comps)
            }
            if ok { scheduled[b.id] = b }
        }
    }

    /// Waits until queued backup changes (and a pending permission answer) are done.
    func backupsSettled() async {
        await authTask?.value
        await syncTask?.value
    }

    /// Asks for notification permission the first time a timer or alarm is made. When it is
    /// granted, every backup is scheduled again (adds before the answer were refused).
    private func askForNotificationsOnce() {
        guard let notify = notifier, notify.isAvailable, !defaults.bool(forKey: Self.askedKey) else { return }
        defaults.set(true, forKey: Self.askedKey)
        authTask = Task { @MainActor [weak self] in
            let granted = await notify.requestAuthorization()
            guard granted, !Task.isCancelled, let self, self.context != nil else { return }
            // Adds refused before the answer were never recorded in `scheduled`, so the
            // diff schedules them now; recorded ones stay tracked (none orphaned, B7).
            self.syncBackups()
        }
    }

    // MARK: - Ringing

    private func ring(_ r: Ring, sound kind: TimeSound) {
        guard let context, !ringing.contains(where: { $0.id == r.id }) else { return }
        ringing.append(r)
        guard context.ring(id: r.id, title: r.title) else {
            ringing.removeAll { $0.id == r.id }
            return
        }
        // The alarm sound wins over a timer's chime.
        play(ringing.contains(where: \.isAlarm) ? .alarm : kind)
        soundTask?.cancel()
        soundTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.soundLimit))
            guard !Task.isCancelled else { return }
            self?.silence()
        }
        if !r.isAlarm {
            ringTimeouts[r.id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(Self.timerRingTime))
                guard !Task.isCancelled else { return }
                self?.endRing(r.id, dismiss: false)   // becomes a "Done" notice
            }
        }
    }

    private func play(_ kind: TimeSound) {
        guard playing != kind else { return }
        sound.play(kind)
        playing = kind
    }

    private func silence() {
        sound.stop()
        playing = nil
    }

    /// Stop: the ring ends; a stopped timer is reset (and its notice dismissed).
    func stopRing(_ id: String) { endRing(id, dismiss: true) }

    /// Snooze (alarms): rings again in 9 minutes.
    func snoozeRing(_ id: String) {
        guard let r = ringing.first(where: { $0.id == id }), case .alarm(let alarmID) = r.kind else { return }
        endRing(id, dismiss: false)
        mutate { $0.snoozeAlarm(alarmID, at: self.clock()) }
    }

    private func endRing(_ id: String, dismiss: Bool) {
        guard let r = ringing.first(where: { $0.id == id }) else { return }
        ringing.removeAll { $0.id == id }
        ringTimeouts.removeValue(forKey: id)?.cancel()
        if context?.ringing.contains(id) == true { context?.stopRinging(id: id) }
        if ringing.isEmpty {
            soundTask?.cancel()
            soundTask = nil
            silence()
        } else if playing != nil {
            // Still within the sound limit: follow what still rings (an alarm, else the chime).
            play(ringing.contains(where: \.isAlarm) ? .alarm : .chime)
        }
        if dismiss, case .timer(let timerID) = r.kind {
            finished[timerID] = nil
            mutate { s in
                if let i = s.timers.firstIndex(where: { $0.id == timerID }) { s.timers[i].reset() }
            }
        }
    }

    /// The panel's chip and the menu bar's "Stop <title>" end rings through `PanelSurfaces`:
    /// treat a ring of ours that disappears there as Stop.
    private func watchRings() {
        guard let surfaces = context?.surfaces else { return }
        watchGeneration += 1
        let generation = watchGeneration
        let current = withObservationTracking {
            surfaces.ringing
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.watchGeneration == generation else { return }
                self.watchRings()
            }
        }
        for r in ringing where !current.contains(r.id) { stopRing(r.id) }
    }

    // MARK: - Live activities

    var liveActivities: [LiveActivity] {
        var out: [LiveActivity] = []
        for r in ringing {
            out.append(LiveActivity(id: "time:ring:\(r.id)", widgetID: id,
                                    priority: r.isAlarm ? LivePriority.alarmRinging : LivePriority.timerFinished,
                                    glyph: .symbol(r.isAlarm ? "alarm.fill" : "timer"), trailing: r.isAlarm ? nil : "Done",
                                    tint: r.isAlarm ? .critical : .warning, accessibilityLabel: "\(r.title) ringing",
                                    title: r.title, subtitle: r.subtitle))
        }
        let ringingTimers = Set(ringing.compactMap { r -> UUID? in if case .timer(let t) = r.kind { t } else { nil } })
        if let latest = finished.filter({ !ringingTimers.contains($0.key) }).max(by: { $0.value < $1.value }),
           let timer = state.timers.first(where: { $0.id == latest.key }) {
            let (timerID, end) = (latest.key, latest.value)
            out.append(LiveActivity(id: "time:done:\(timerID.uuidString)", widgetID: id, priority: LivePriority.timerFinished,
                                    glyph: .symbol("checkmark.circle.fill"), trailing: "Done", tint: .warning,
                                    expiresAt: end.addingTimeInterval(Self.noticeTime),
                                    accessibilityLabel: "\(timer.label.isEmpty ? "Timer" : timer.label) done",
                                    title: timer.label.isEmpty ? "Timer" : timer.label, subtitle: "Done", startedAt: end))
        }
        if let next = state.timers.filter({ $0.isRunning(at: now) }).min(by: { $0.endsAt! < $1.endsAt! }),
           let end = next.endsAt {
            out.append(LiveActivity(id: "time:timer:\(next.id.uuidString)", widgetID: id, priority: LivePriority.timerRunning,
                                    glyph: .symbol("timer"), tint: .accent, expiresAt: end, countdownTo: end,
                                    accessibilityLabel: "\(next.label.isEmpty ? "Timer" : next.label) running",
                                    title: next.label.isEmpty ? "Timer" : next.label))
        }
        if let since = state.stopwatch.runningSince {
            out.append(LiveActivity(id: "time:stopwatch", widgetID: id, priority: LivePriority.stopwatch,
                                    glyph: .symbol("stopwatch"), tint: .accent,
                                    countUpFrom: since.addingTimeInterval(-state.stopwatch.accumulated),
                                    accessibilityLabel: "Stopwatch running", title: "Stopwatch"))
        }
        return out
    }

    // MARK: - Views

    var kind: WidgetKind { [.live, .tool] }

    /// The top timer, stopwatch or ring with Stop or Pause (a finished timer's notice has none).
    func heroView() -> AnyView? {
        AnyView(TopActivityHero(activities: { [weak self] in self?.liveActivities ?? [] }, action: { [weak self] activity in
            self?.heroAction(activity)
        }))
    }

    /// Stop for a ringing alarm or timer, Pause for a running timer or the stopwatch.
    func heroAction(_ activity: LiveActivity) -> HeroAction? {
        let rank: LiveRank = LiveRank(activity: activity, now: now)
        guard let title = HeroPrimary.title(rank: rank, playing: false, hasLink: false) else { return nil }
        let id: String = activity.id
        if id.hasPrefix("time:ring:") {
            let ring = String(id.dropFirst("time:ring:".count))
            return HeroAction(title: title, systemImage: "stop.fill", run: { [weak self] in self?.stopRing(ring) })
        }
        if id.hasPrefix("time:timer:"), let uuid = UUID(uuidString: String(id.dropFirst("time:timer:".count))) {
            return HeroAction(title: title, systemImage: "pause.fill", run: { [weak self] in self?.toggleTimer(uuid) })
        }
        if id == "time:stopwatch" {
            return HeroAction(title: title, systemImage: "pause.fill", run: { [weak self] in self?.toggleStopwatch() })
        }
        return nil
    }

    func tileView() -> AnyView { AnyView(TimeTile(widget: self)) }

    func peekView(id: String) -> AnyView? {
        guard let r = ringing.first(where: { $0.id == id }) else { return nil }
        return AnyView(RingingOverlay(title: r.title, subtitle: r.subtitle, isAlarm: r.isAlarm,
                                      onSnooze: r.isAlarm ? { [weak self] in self?.snoozeRing(id) } : nil,
                                      onStop: { [weak self] in self?.stopRing(id) }))
    }

    func settingsView() -> AnyView? { AnyView(TimeSettings()) }

    // MARK: - Changes from the tile

    /// Applies a change after handling anything already due, then saves and reschedules.
    private func mutate(_ change: (inout TimeState) -> Void) {
        tick()
        store.update(change)
        state = store.state
        syncBackups()
        scheduleWake()
    }

    var timersFull: Bool { state.timers.count >= TimeStore.maxTimers }
    var alarmsFull: Bool { state.alarms.count >= TimeStore.maxAlarms }
    var clocksFull: Bool { state.clocks.count >= TimeStore.maxClocks }

    /// The quick-add field: a duration (`DurationParser`) or "pomodoro" (25 + 5). Starts it.
    @discardableResult
    func addTimer(_ text: String) -> Bool {
        let input = text.trimmingCharacters(in: .whitespaces)
        if input.lowercased() == "pomodoro" { return startPomodoro() }
        guard let duration = DurationParser.parse(input) else { return false }
        return add(duration: duration, label: nil)
    }

    /// `TimerStarter`: only while the widget runs (a disabled widget does nothing, R7).
    @discardableResult
    func startTimer(duration: TimeInterval, label: String?) -> Bool {
        guard context != nil, duration > 0, duration <= DurationParser.maximum else { return false }
        return add(duration: duration, label: label)
    }

    private func add(duration: TimeInterval, label: String?) -> Bool {
        guard !timersFull else { return false }
        let name = label.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        var t = CountdownTimer(label: name.isEmpty ? DurationParser.describe(duration) : String(name.prefix(60)),
                               duration: duration)
        t.start(at: clock())
        mutate { $0.timers.append(t) }
        askForNotificationsOnce()
        return true
    }

    @discardableResult
    func startPomodoro() -> Bool {
        guard !timersFull else { return false }
        mutate { $0.startPomodoro(at: self.clock()) }
        askForNotificationsOnce()
        return true
    }

    func toggleTimer(_ id: UUID) {
        if ringing.contains(where: { $0.kind == .timer(id) }) { endRing(TimeBackup.timerID(id), dismiss: false) }
        mutate { s in
            guard let i = s.timers.firstIndex(where: { $0.id == id }) else { return }
            let t = self.clock()
            switch s.timers[i].phase {
            case .running where s.timers[i].isFinished(at: t): s.timers[i].reset(); s.timers[i].start(at: t)
            case .running: s.timers[i].pause(at: t)
            case .paused: s.timers[i].resume(at: t)
            case .idle: s.timers[i].start(at: t)
            }
        }
        finished[id] = nil
    }

    func resetTimer(_ id: UUID) {
        if ringing.contains(where: { $0.kind == .timer(id) }) { stopRing(TimeBackup.timerID(id)); return }
        finished[id] = nil
        mutate { s in if let i = s.timers.firstIndex(where: { $0.id == id }) { s.timers[i].reset() } }
    }

    func removeTimer(_ id: UUID) {
        if ringing.contains(where: { $0.kind == .timer(id) }) { endRing(TimeBackup.timerID(id), dismiss: false) }
        finished[id] = nil
        mutate { $0.timers.removeAll { $0.id == id } }
    }

    func toggleStopwatch() {
        mutate { s in
            let t = self.clock()
            if s.stopwatch.isRunning { s.stopwatch.stop(at: t) } else { s.stopwatch.start(at: t) }
        }
    }

    func lapOrResetStopwatch() {
        mutate { s in
            if s.stopwatch.isRunning { s.stopwatch.lap(at: self.clock()) } else { s.stopwatch.reset() }
        }
    }

    @discardableResult
    func addAlarm(hour: Int, minute: Int, weekdays: Set<Int> = [], label: String = "") -> Bool {
        guard !alarmsFull else { return false }
        mutate { $0.alarms.append(Alarm(hour: hour, minute: minute, weekdays: weekdays,
                                        label: label.trimmingCharacters(in: .whitespaces))) }
        askForNotificationsOnce()
        return true
    }

    func setAlarmEnabled(_ id: UUID, _ on: Bool) {
        mutate { $0.setAlarmEnabled(id, on) }
    }

    func toggleWeekday(_ id: UUID, _ day: Int) {
        mutate { s in
            guard let i = s.alarms.firstIndex(where: { $0.id == id }) else { return }
            if s.alarms[i].weekdays.contains(day) { s.alarms[i].weekdays.remove(day) } else { s.alarms[i].weekdays.insert(day) }
        }
    }

    func removeAlarm(_ id: UUID) {
        if ringing.contains(where: { $0.kind == .alarm(id) }) { endRing(TimeBackup.alarmID(id), dismiss: false) }
        mutate { $0.alarms.removeAll { $0.id == id } }
    }

    @discardableResult
    func addClock(_ timeZoneID: String) -> Bool {
        guard !clocksFull, TimeZone(identifier: timeZoneID) != nil else { return false }
        mutate { $0.clocks.append(WorldClock(timeZoneID: timeZoneID)) }
        return true
    }

    func removeClock(_ id: UUID) {
        mutate { $0.clocks.removeAll { $0.id == id } }
    }

    /// "7:30 AM" / "07:30" in the user's locale.
    static func timeText(hour: Int, minute: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// Settings › Widgets › Time.
private struct TimeSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsNote("Each running timer and each alarm also schedules a system notification, so it still goes off when PlatyNotch is not running or the Mac restarted. PlatyNotch asks for notification permission when you make your first timer or alarm.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsNote("Alarms and timers ring during focus sessions too, unless Settings › Notifications keeps them quiet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Notification Settings…") { Permissions.open(.notifications) }
                .disabled(!Permissions.canUseNotifications)
        }
    }
}
