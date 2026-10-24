import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Meetings in the next 12 hours: a tile with the next meeting (and the one in progress)
/// with a Join button, a countdown ring in the pill for the last 10 minutes, and a peek
/// below the notch at 10, 5 and 1 minutes before the start (`MeetingReminderSchedule`).
///
/// Calendar access is asked for only from a button (the tile's "Allow Calendar Access",
/// this widget's settings or Settings › Permissions). While enabled with access, the
/// widget re-reads the events every `refreshInterval` (sooner at a reminder, start or
/// end), on every calendar change (`EKEventStoreChanged`) and after the Mac wakes. Without
/// access there is no timer at all (C13): it wakes only when the access status changes
/// (an Allow button, the tile re-reading it when shown) or after the Mac wakes.
/// Turned off, it reads nothing and observes nothing.
///
/// Reminder peeks stay quiet during a PlatyNotch focus session (the pill countdown still
/// shows). A join link is never opened by itself: only the Join buttons open it.
@MainActor @Observable
final class MeetingWidget: NotchWidget {
    static let widgetID = "meeting"
    static let refreshInterval: TimeInterval = 30
    static let reminderPeekID = "meeting.reminder"
    /// How long a reminder peek stays (never past the start).
    static let reminderPeekTime: TimeInterval = 12

    /// A reminder on show.
    struct Reminder: Equatable {
        let meeting: CalendarMeeting
        /// 10, 5 or 1.
        let minutes: Int
    }

    let id = MeetingWidget.widgetID
    let title = "Meetings"
    let systemImage = "calendar"
    let defaultEnabled = true
    @ObservationIgnored let calendar: CalendarService

    /// Advanced on every wake-up so `liveActivities` follows the clock.
    private(set) var now: Date
    private(set) var reminder: Reminder?

    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var context: WidgetContext?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// Reminder offsets already shown (or skipped), per meeting occurrence.
    @ObservationIgnored private var shown: [String: Set<Int>] = [:]

    init(calendar: CalendarService, defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.defaults = defaults
        self.clock = clock
        now = clock()
    }

    /// In a meeting right now (timed, not declined). For the wellbeing nudges (Task 8).
    var inMeeting: Bool { current != nil }

    var current: CalendarMeeting? {
        calendar.access == .granted ? MeetingTimeline.current(calendar.meetings, now: now) : nil
    }

    var liveActivities: [LiveActivity] {
        guard calendar.access == .granted, let next = MeetingTimeline.next(calendar.meetings, now: now) else { return [] }
        let lead = next.start.timeIntervalSince(now)
        guard lead > 0, lead <= LivePriority.meetingSoonWindow else { return [] }
        return [LiveActivity(id: "meeting:next", widgetID: id, priority: LivePriority.meetingSoon,
                             glyph: .ring(progress: MeetingReminderSchedule.progress(start: next.start, now: now)),
                             tint: .warning, expiresAt: next.start, countdownTo: next.start,
                             accessibilityLabel: "\(next.title) \(TodayFormat.meetingWhen(start: next.start, now: now).lowercased())")]
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        self.context = context
        calendar.startWatching()
        observeWake()
        observeAccess()
        tick()
    }

    /// A wake-up is scheduled (tests: none without calendar access).
    var hasWakeScheduled: Bool { task != nil }

    /// Ticks when the access status changes, while running (no polling for a grant).
    private func observeAccess() {
        withObservationTracking {
            _ = calendar.access
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.context != nil else { return }
                self.tick()
                self.observeAccess()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        calendar.stopWatching()
        if reminder != nil { context?.endPeek(id: Self.reminderPeekID) }
        reminder = nil
        context = nil
    }

    func disabled() {
        shown = [:]
    }

    /// Re-reads access and events, shows a due reminder, and sleeps until the next change.
    func tick() {
        guard context != nil else { return }
        calendar.refreshAccess()
        calendar.refresh()
        now = clock()
        checkReminders()
        scheduleWake()
    }

    private func scheduleWake() {
        task?.cancel()
        task = nil
        guard calendar.access == .granted else { return }   // C13: no 30 s wakes without access
        let wake = MeetingTimeline.nextWake(calendar.meetings, now: now).map { $0.timeIntervalSince(now) + 0.05 }
        let delay = min(Self.refreshInterval, max(0.05, wake ?? Self.refreshInterval))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.tick()
        }
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Reminders

    private func checkReminders() {
        guard let context, calendar.access == .granted else { return }
        let upcoming = MeetingTimeline.upcoming(calendar.meetings, now: now).filter { $0.start > now }
        shown = shown.filter { id, _ in calendar.meetings.contains { $0.id == id } }
        var due: Reminder?
        for m in upcoming {
            let seen = shown[m.id] ?? []
            guard let minutes = MeetingReminderSchedule.due(start: m.start, now: now, shown: seen) else { continue }
            shown[m.id] = seen.union(MeetingReminderSchedule.crossed(start: m.start, now: now))
            if due == nil { due = Reminder(meeting: m, minutes: minutes) }
        }
        if let r = reminder, r.meeting.start <= now || !calendar.meetings.contains(where: { $0.id == r.meeting.id }) {
            context.endPeek(id: Self.reminderPeekID)
            reminder = nil
        }
        guard let due, !focusSessionActive else { return }
        reminder = due
        let until = min(now.addingTimeInterval(Self.reminderPeekTime), due.meeting.start)
        if !context.peek(id: Self.reminderPeekID, until: until) { reminder = nil }
    }

    /// `FocusModel` publishes the end of a running focus session under `untilKey`.
    private var focusSessionActive: Bool {
        (defaults.object(forKey: FocusModel.untilKey) as? Date).map { $0 > now } ?? false
    }

    /// Opens a join link (only ever from a Join button).
    func join(_ meeting: CalendarMeeting) {
        guard let url = meeting.joinURL else { return }
        NSWorkspace.shared.open(url)
        if reminder?.meeting.id == meeting.id {
            context?.endPeek(id: Self.reminderPeekID)
            reminder = nil
        }
    }

    // MARK: - Views

    func peekView(id: String) -> AnyView? {
        guard id == Self.reminderPeekID, let reminder else { return nil }
        return AnyView(MeetingReminderPeek(reminder: reminder, join: { [weak self] in self?.join(reminder.meeting) }))
    }

    func tileView() -> AnyView {
        AnyView(MeetingTile(widget: self))
    }

    func settingsView() -> AnyView? {
        AnyView(MeetingSettings(calendar: calendar))
    }
}
