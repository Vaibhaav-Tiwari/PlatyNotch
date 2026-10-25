import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Reminders due today and overdue, ticked off from the tile, and quick add ("call Priya at
/// 5pm", "meeting with Sam tomorrow 3pm for 30 min"): `QuickAddParser` decides between a
/// reminder (to the list chosen in settings) and a calendar event (needs Calendar access;
/// without it the text is saved as a reminder and the tile says so).
///
/// Off by default (it reads private data). Reminders access is asked for only from the
/// tile's or settings' Allow button. While enabled it re-reads on every Reminders change,
/// after wake, and every `refreshInterval` (so "overdue" follows the clock). Turned off it
/// reads and observes nothing.
@MainActor @Observable
final class RemindersWidget: NotchWidget {
    static let widgetID = "reminders"
    static let refreshInterval: TimeInterval = 5 * 60
    static let shownLimit = 6

    let id = RemindersWidget.widgetID
    let title = "Reminders"
    let systemImage = "checkmark.circle"
    let defaultEnabled = false
    @ObservationIgnored let reminders: RemindersService
    @ObservationIgnored let calendar: CalendarService

    /// The quick-add field's text.
    var draft = ""
    /// What the last add or tick did ("Added to Reminders"), or why it failed.
    private(set) var status: String?
    private(set) var now: Date

    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let cal: () -> Calendar
    @ObservationIgnored private var running = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var statusTask: Task<Void, Never>?

    init(reminders: RemindersService, calendar: CalendarService, clock: @escaping () -> Date = Date.init,
         calendarNow: @escaping () -> Calendar = { Calendar.autoupdatingCurrent }) {
        self.reminders = reminders
        self.calendar = calendar
        self.clock = clock
        cal = calendarNow
        now = clock()
    }

    /// A copy that never touches EventKit (smoke runs).
    static func inert() -> RemindersWidget {
        RemindersWidget(reminders: RemindersService(eventKit: false), calendar: CalendarService(eventKit: false))
    }

    func start(context: WidgetContext) {
        running = true
        reminders.startWatching()
        observeWake()
        loop()
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        statusTask?.cancel()
        statusTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        reminders.stopWatching()
    }

    private func loop() {
        task?.cancel()
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
                guard !Task.isCancelled, let self, self.running else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard running else { return }
        reminders.refreshAccess()
        now = clock()
        await reminders.refresh()
    }

    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }

    /// Asks for Reminders access (the Allow button), then reads.
    func allow() async {
        await reminders.requestAccess()
        await refresh()
    }

    /// What `draft` would create.
    func parsed(at date: Date? = nil) -> QuickAdd {
        QuickAddParser.parse(draft, now: date ?? clock(), calendar: cal())
    }

    func preview(at date: Date) -> String? {
        let q = parsed(at: date)
        guard !q.title.isEmpty else { return nil }
        var text = QuickAddFormat.preview(q, now: date, calendar: cal())
        if q.isEvent, calendar.accessNow != .granted { text += " (saved as a reminder: Calendar access is off)" }
        return text
    }

    /// Adds what `draft` says (a reminder, or an event with Calendar access), then clears it.
    func addDraft() {
        guard running, reminders.access == .granted else { return }
        let q = parsed()
        guard !q.title.isEmpty else { return }
        // A grant or revoke made in System Settings since the last read counts (never prompts).
        calendar.refreshAccess()
        do {
            if q.isEvent, calendar.access == .granted, let start = q.due, let end = q.eventEnd {
                try calendar.addEvent(title: q.title, start: start, end: end)
                show("Added to Calendar")
            } else {
                try reminders.add(title: q.title, due: q.due, hasTime: q.hasTime)
                show(q.isEvent ? "Added to Reminders (Calendar access is off)" : "Added to Reminders")
            }
            draft = ""
        } catch {
            show(error.localizedDescription)
        }
    }

    func complete(_ item: ReminderItem) {
        guard running else { return }
        do { try reminders.complete(id: item.id) } catch { show(error.localizedDescription) }
    }

    private func show(_ text: String) {
        status = text
        statusTask?.cancel()
        statusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    /// Today's and overdue reminders in tile order.
    func shown(at date: Date) -> [ReminderItem] {
        RemindersDay.today(reminders.items, now: date, calendar: cal())
    }

    func isOverdue(_ item: ReminderItem, at date: Date) -> Bool {
        RemindersDay.isOverdue(item, now: date, calendar: cal())
    }

    func dueText(_ item: ReminderItem, at date: Date) -> String {
        RemindersDay.dueText(item, now: date, calendar: cal())
    }

    var kind: WidgetKind { [.glance, .tool] }

    /// Reminders due today (and overdue), only with Reminders access (never asks).
    var dueCount: Int {
        reminders.access == .granted ? shown(at: now).count : 0
    }

    var hasContent: Bool { dueCount > 0 }

    /// "Tasks 3".
    func glanceView() -> AnyView? { AnyView(RemindersGlance(widget: self)) }

    func tileView() -> AnyView {
        AnyView(RemindersTile(widget: self))
    }

    func settingsView() -> AnyView? {
        AnyView(RemindersSettings(widget: self))
    }
}

/// The reminders glance: how many are due today.
private struct RemindersGlance: View {
    let widget: RemindersWidget

    var body: some View {
        GlanceChip(systemImage: widget.systemImage, value: "\(widget.dueCount)", label: "Tasks")
    }
}
