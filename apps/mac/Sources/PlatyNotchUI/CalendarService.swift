import AppKit
import EventKit
import Observation
import PlatyNotchKit

/// The user's meetings in the next 12 hours (EventKit events), for the meeting widget and
/// quick-add events. Access is asked for only from a button (the meeting tile's "Allow
/// Calendar Access", its settings, or Settings › Permissions), never at launch or when a
/// tile appears. Reads happen only while the meeting widget runs (`startWatching`).
/// Without `NSCalendarsFullAccessUsageDescription` in the bundle we never ask (macOS would
/// kill the app): access is `.unavailable` then (e.g. `swift run`).
@MainActor @Observable
public final class CalendarService {
    public enum Access: Equatable, Sendable {
        case notAsked
        case granted
        /// Denied, restricted or write-only: the tile offers System Settings.
        case denied
        /// This build has no usage description (e.g. `swift run`), or EventKit is off (smoke, tests).
        case unavailable
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    static let usageKey = "NSCalendarsFullAccessUsageDescription"

    public private(set) var access: Access
    /// Timed and all-day events overlapping the next 12 hours (from 10 min ago), by start.
    public private(set) var meetings: [CalendarMeeting] = []
    /// Each meeting's calendar color, by meeting id.
    public private(set) var colors: [String: CGColor] = [:]

    /// Set by the app: "Calendar access is off › Open Settings" goes to Settings › Permissions.
    @ObservationIgnored public var onOpenSettings: (() -> Void)?
    @ObservationIgnored private let eventKit: Bool
    /// Created on first use (reading the authorization status needs no store).
    @ObservationIgnored private var storage: EKEventStore?
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var requesting = false
    /// Join links found per event (eventIdentifier), redone only when the event changes.
    @ObservationIgnored private var joinCache: [String: (modified: Date?, url: URL?)] = [:]
    /// True while the meeting widget runs: only then are events read and changes observed.
    @ObservationIgnored public private(set) var watching = false

    /// `eventKit: false` never touches EventKit (smoke runs and tests): access is `.unavailable`.
    public init(eventKit: Bool = true) {
        self.eventKit = eventKit
        access = eventKit ? Self.currentAccess() : .unavailable
    }

    private var store: EKEventStore {
        if let storage { return storage }
        let s = EKEventStore()
        storage = s
        return s
    }

    /// The authorization status right now, without storing it or prompting (safe to read
    /// while a view is drawn).
    public var accessNow: Access {
        eventKit ? Self.currentAccess() : access
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
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
            store.requestFullAccessToEvents { @Sendable granted, _ in cont.resume(returning: granted) }
        }
        requesting = false
        if granted { storage?.reset() }
        refreshAccess()
    }

    /// Re-reads the authorization status (never prompts). A grant made in System Settings
    /// starts the reads when watching; a revoke clears what was read.
    public func refreshAccess() {
        guard eventKit else { return }
        let was = access
        access = Self.currentAccess()
        guard access != was else { return }
        if access == .granted, watching {
            observeChanges()
            refresh()
        } else if access != .granted {
            stopObservingChanges()
            meetings = []
            colors = [:]
            joinCache = [:]
        }
    }

    /// The meeting widget started: read now and on every calendar change.
    public func startWatching() {
        watching = true
        refreshAccess()
        guard access == .granted else { return }
        observeChanges()
        refresh()
    }

    /// The meeting widget stopped: no observer, nothing kept.
    public func stopWatching() {
        watching = false
        stopObservingChanges()
        meetings = []
        colors = [:]
        joinCache = [:]
    }

    /// Re-reads the next 12 hours (only while watching and allowed).
    public func refresh() {
        guard eventKit, watching, access == .granted else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-UpcomingMeeting.grace),
                                                 end: now.addingTimeInterval(UpcomingMeeting.horizon),
                                                 calendars: nil)
        var found: [CalendarMeeting] = []
        var colors: [String: CGColor] = [:]
        var cache: [String: (modified: Date?, url: URL?)] = [:]
        for e in store.events(matching: predicate) {
            let key = e.eventIdentifier ?? e.calendarItemIdentifier
            let id = "\(key)@\(Int(e.startDate.timeIntervalSince1970))"
            let title = e.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let joinURL: URL?
            if let hit = joinCache[key] ?? cache[key], hit.modified == e.lastModifiedDate {
                joinURL = hit.url
            } else {
                joinURL = MeetingLinks.firstJoinURL(url: e.url, location: e.location, notes: e.notes)
            }
            cache[key] = (e.lastModifiedDate, joinURL)
            found.append(CalendarMeeting(id: id, title: title.isEmpty ? "Untitled event" : title,
                                         start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                                         declined: Self.isDeclined(e), joinURL: joinURL))
            if let c = e.calendar?.cgColor { colors[id] = c }
        }
        joinCache = cache
        found.sort { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
        if found != meetings { meetings = found }
        if colors != self.colors { self.colors = colors }
    }

    /// The tile's next meeting: the earliest one starting within 12 h or started in the last 10 min.
    public func next(at now: Date) -> CalendarMeeting? {
        let entries = meetings.map { CalendarEntry(id: $0.id, start: $0.start, end: $0.end, isAllDay: $0.isAllDay, declined: $0.declined) }
        guard let picked = UpcomingMeeting.pick(entries, now: now) else { return nil }
        return meetings.first { $0.id == picked.id }
    }

    /// Adds an event to the default calendar (quick add). Needs full access.
    public func addEvent(title: String, start: Date, end: Date) throws {
        guard eventKit, access == .granted else { throw CalendarWriteError.noAccess }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        guard let calendar = store.defaultCalendarForNewEvents else { throw CalendarWriteError.noCalendar }
        event.calendar = calendar
        try store.save(event, span: .thisEvent, commit: true)
        refresh()
    }

    /// Where quick-add events go (Settings shows it).
    public var defaultCalendarTitle: String? {
        guard eventKit, access == .granted else { return nil }
        return store.defaultCalendarForNewEvents?.title
    }

    /// Opens PlatyNotch Settings at Permissions when wired (the app does), else System Settings.
    public func openSettings() {
        if let onOpenSettings { onOpenSettings() } else { NSWorkspace.shared.open(Self.settingsURL) }
    }

    /// Tests: pretend EventKit answered.
    func setForTesting(access: Access, meetings: [CalendarMeeting]) {
        self.access = access
        self.meetings = meetings
    }

    private static func isDeclined(_ e: EKEvent) -> Bool {
        if e.status == .canceled { return true }
        return e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private func observeChanges() {
        guard changeObserver == nil, eventKit else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func stopObservingChanges() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        changeObserver = nil
    }
}

public enum CalendarWriteError: LocalizedError, Equatable {
    case noAccess, noCalendar, noList, notFound

    public var errorDescription: String? {
        switch self {
        case .noAccess: "PlatyNotch is not allowed to change your calendar."
        case .noCalendar: "There is no calendar to add events to."
        case .noList: "There is no Reminders list to add to."
        case .notFound: "That reminder is gone."
        }
    }
}
