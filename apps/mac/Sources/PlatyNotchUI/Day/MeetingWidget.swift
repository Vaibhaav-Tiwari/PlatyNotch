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
                             accessibilityLabel: "\(next.title) \(TodayFormat.meetingWhen(start: next.start, now: now).lowercased())",
                             title: next.title, subtitle: Self.time(next.start), startedAt: next.start)]
    }

    var kind: WidgetKind { [.glance, .live, .tool] }

    /// The glance's meeting: the next (or current) one within `UpcomingMeeting.horizon`,
    /// only with calendar access (never asks).
    var glanceMeeting: CalendarMeeting? {
        guard calendar.access == .granted else { return nil }
        return MeetingTimeline.upcoming(calendar.meetings, now: now).first
    }

    var hasContent: Bool { glanceMeeting != nil }

    /// The next meeting: its title, start time, a countdown and Join when it has a link.
    func heroView() -> AnyView? { AnyView(MeetingHero(widget: self)) }

    /// "10:30 Design".
    func glanceView() -> AnyView? {
        AnyView(MeetingGlance(widget: self))
    }

    /// "10:30" in the user's locale.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        self.context = context
        calendar.startWatching()
        observeWake()
        accessGeneration += 1
        observeAccess(generation: accessGeneration)
        tick()
    }

    /// Bumped on every start and stop: an observation chain from an earlier run stops.
    @ObservationIgnored private var accessGeneration = 0
    /// How many ticks ran (tests).
    @ObservationIgnored private(set) var ticks = 0

    /// A wake-up is scheduled (tests: none without calendar access).
    var hasWakeScheduled: Bool { task != nil }

    /// Ticks when the access status changes, while running (no polling for a grant).
    private func observeAccess(generation: Int) {
        withObservationTracking {
            _ = calendar.access
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.context != nil, self.accessGeneration == generation else { return }
                self.tick()
                self.observeAccess(generation: generation)
            }
        }
    }

    func stop() {
        accessGeneration += 1   // the access observation from this run ends
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
        ticks += 1
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

/// The meeting glance: the start time and the event's title.
struct MeetingGlance: View {
    let widget: MeetingWidget

    var body: some View {
        let m = widget.glanceMeeting
        GlanceChip(systemImage: "calendar", value: m.map { Self.value($0, now: widget.now) } ?? "—",
                   label: m?.title ?? "No meetings")
    }

    /// "10:30", or "Now" for a meeting in progress (the chip reads "Now: Design" aloud).
    static func value(_ m: CalendarMeeting, now: Date) -> String {
        m.start <= now ? "Now" : MeetingWidget.time(m.start)
    }
}

/// The meeting hero: the next meeting within 10 minutes (its live item).
private struct MeetingHero: View {
    let widget: MeetingWidget

    var body: some View {
        if let next = widget.calendar.access == .granted ? MeetingTimeline.next(widget.calendar.meetings, now: widget.now)
                                                          : nil {
            HeroLayout(title: next.title, subtitle: "Starts at \(MeetingWidget.time(next.start))",
                       action: join(next)) {
                HeroGlyph(glyph: .ring(progress: MeetingReminderSchedule.progress(start: next.start, now: widget.now)),
                          tint: .warning)
            } value: {
                HeroClock(countdownTo: next.start, countUpFrom: nil, style: .minutesUntil)
            }
        }
    }

    private func join(_ m: CalendarMeeting) -> HeroAction? {
        let hasLink: Bool = m.joinURL != nil
        let rank: LiveRank = m.start.timeIntervalSince(widget.now) <= LiveRank.imminentWindow ? .meetingImminent : .meetingSoon
        guard let title = HeroPrimary.title(rank: rank, playing: false, hasLink: hasLink), let url = m.joinURL else {
            return nil
        }
        return HeroAction(title: title, systemImage: "video.fill", run: { NSWorkspace.shared.open(url) })
    }
}
