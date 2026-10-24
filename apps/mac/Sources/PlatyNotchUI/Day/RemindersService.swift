import AppKit
import EventKit
import Observation
import PlatyNotchKit

/// The user's reminders (EventKit, its own `EKEventStore`). Access is asked for only from
/// an Allow button (the Reminders tile or settings, Settings › Permissions), never at
/// launch. Reads happen only while the Reminders widget runs (`startWatching`). Without
/// `NSRemindersFullAccessUsageDescription` in the bundle we never ask.
@MainActor @Observable
public final class RemindersService {
    public typealias Access = CalendarService.Access

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")!
    static let usageKey = "NSRemindersFullAccessUsageDescription"
    /// The list quick add uses (`calendarIdentifier`); absent = the Reminders default list.
    static let defaultListKey = "reminders.defaultList"

    public private(set) var access: Access
    /// Incomplete reminders due by the end of today (overdue included).
    public private(set) var items: [ReminderItem] = []
    public private(set) var lists: [ReminderList] = []
    /// The list quick add uses (nil = the Reminders default list).
    public var defaultListID: String? {
        didSet { defaults.set(defaultListID, forKey: Self.defaultListKey) }
    }

    @ObservationIgnored private let eventKit: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var storage: EKEventStore?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var requesting = false
    @ObservationIgnored public private(set) var watching = false
    /// Increments per fetch so an older fetch's answer never overwrites a newer one.
    @ObservationIgnored private var generation = 0

    /// `eventKit: false` never touches EventKit (smoke runs and tests): access is `.unavailable`.
    public init(eventKit: Bool = true, defaults: UserDefaults = .standard) {
        self.eventKit = eventKit
        self.defaults = defaults
        access = eventKit ? Self.currentAccess() : .unavailable
        defaultListID = defaults.string(forKey: Self.defaultListKey)
    }

    private var store: EKEventStore {
        if let storage { return storage }
        let s = EKEventStore()
        storage = s
        return s
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: .granted
        case .notDetermined:
            Bundle.main.object(forInfoDictionaryKey: usageKey) == nil ? .unavailable : .notAsked
        default: .denied
        }
    }

    /// Shows the system prompt if never asked. Only from an Allow button.
    public func requestAccess() async {
        refreshAccess()
        guard eventKit, access == .notAsked, !requesting else { return }
        requesting = true
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            store.requestFullAccessToReminders { @Sendable granted, _ in cont.resume(returning: granted) }
        }
        requesting = false
        if granted { storage?.reset() }
        refreshAccess()
    }

    /// Re-reads the authorization status (never prompts).
    public func refreshAccess() {
        guard eventKit else { return }
        let was = access
        access = Self.currentAccess()
        guard access != was else { return }
        if access == .granted, watching {
            observeChanges()
            Task { await refresh() }
        } else if access != .granted {
            stopObservingChanges()
            items = []
            lists = []
        }
    }

    public func startWatching() {
        watching = true
        refreshAccess()
        guard access == .granted else { return }
        observeChanges()
        Task { await refresh() }
    }

    public func stopWatching() {
        watching = false
        generation += 1
        stopObservingChanges()
        items = []
        lists = []
    }

    /// Re-reads today's and overdue reminders and the lists (only while watching and allowed).
    public func refresh() async {
        guard eventKit, watching, access == .granted else { return }
        generation += 1
        let mine = generation
        let cal = Calendar.current
        guard let endOfToday = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) else { return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: endOfToday, calendars: nil)
        let found: [ReminderItem] = await withCheckedContinuation { cont in
            _ = store.fetchReminders(matching: predicate) { @Sendable reminders in
                cont.resume(returning: (reminders ?? []).compactMap(Self.item))
            }
        }
        guard mine == generation, watching else { return }
        items = found
        lists = store.calendars(for: .reminder)
            .map { ReminderList(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        if let id = defaultListID, !lists.contains(where: { $0.id == id }) { defaultListID = nil }
    }

    /// Runs on EventKit's queue: reads only plain values.
    private nonisolated static func item(_ r: EKReminder) -> ReminderItem? {
        guard !r.isCompleted else { return nil }
        let comps = r.dueDateComponents
        let hasTime = comps?.hour != nil
        var cal = comps?.calendar ?? Calendar.current
        if let tz = comps?.timeZone { cal.timeZone = tz }
        let due = comps.flatMap { c -> Date? in
            var plain = c
            plain.calendar = nil
            plain.timeZone = nil
            return cal.date(from: plain)
        }
        let title = r.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ReminderItem(id: r.calendarItemIdentifier, title: title.isEmpty ? "Untitled reminder" : title,
                            due: due, hasTime: hasTime, listTitle: r.calendar?.title ?? "")
    }

    /// Ticks a reminder off.
    public func complete(id: String) throws {
        guard eventKit, access == .granted else { throw CalendarWriteError.noAccess }
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else {
            items.removeAll { $0.id == id }
            throw CalendarWriteError.notFound
        }
        r.isCompleted = true
        try store.save(r, commit: true)
        items.removeAll { $0.id == id }
    }

    /// Adds a reminder to the chosen list. A timed one also gets an alarm at that time.
    public func add(title: String, due: Date?, hasTime: Bool) throws {
        guard eventKit, access == .granted else { throw CalendarWriteError.noAccess }
        let r = EKReminder(eventStore: store)
        r.title = title
        let chosen = defaultListID.flatMap { store.calendar(withIdentifier: $0) }
        guard let list = chosen ?? store.defaultCalendarForNewReminders() else { throw CalendarWriteError.noList }
        r.calendar = list
        if let due {
            let cal = Calendar.current
            var comps = cal.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: due)
            comps.calendar = cal
            comps.timeZone = hasTime ? cal.timeZone : nil
            r.dueDateComponents = comps
            if hasTime { r.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(r, commit: true)
        Task { await refresh() }
    }

    public func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    /// Tests: pretend EventKit answered.
    func setForTesting(access: Access, items: [ReminderItem], lists: [ReminderList] = []) {
        self.access = access
        self.items = items
        self.lists = lists
    }

    private func observeChanges() {
        guard changeObserver == nil, eventKit else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
    }

    private func stopObservingChanges() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }
}
