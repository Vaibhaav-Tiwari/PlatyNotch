import AppKit
import EventKit
import Observation
import PlatyNotchKit

/// The next meeting from the user's calendars. Access is requested only when the Today
/// tab is first shown, never at launch. Info.plist `NSCalendarsFullAccessUsageDescription`
/// is added with packaging (Task 11); without it we do not ask (macOS would kill the app).
@MainActor @Observable
public final class CalendarService {
    public enum Access: Equatable {
        case notAsked
        case granted
        /// Denied, restricted or write-only: the Today tab offers System Settings.
        case denied
        /// This build has no calendar usage description (e.g. `swift run`).
        case unavailable
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
    static let usageKey = "NSCalendarsFullAccessUsageDescription"

    public private(set) var access: Access
    public private(set) var next: EKEvent?
    public private(set) var joinURL: URL?

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var changeObserver: NSObjectProtocol?
    @ObservationIgnored private var requesting = false

    public init() {
        access = Self.currentAccess()
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined:
            Bundle.main.object(forInfoDictionaryKey: usageKey) == nil ? .unavailable : .notAsked
        default: .denied
        }
    }

    /// Asks once (if never asked), then loads the next meeting. Safe to call on every appearance.
    public func requestAccess() async {
        access = Self.currentAccess()
        if access == .notAsked, !requesting {
            requesting = true
            let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                store.requestFullAccessToEvents { granted, _ in cont.resume(returning: granted) }
            }
            requesting = false
            access = granted ? .granted : Self.currentAccess()
        }
        guard access == .granted else { return }
        observeChanges()
        refresh()
    }

    /// Re-reads the next 12 hours. Called on appearance, every minute while shown, and on calendar changes.
    public func refresh() {
        guard access == .granted else { next = nil; joinURL = nil; return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-UpcomingMeeting.grace),
                                                 end: now.addingTimeInterval(UpcomingMeeting.horizon),
                                                 calendars: nil)
        let events = store.events(matching: predicate)
        let entries = events.enumerated().map { i, e in
            CalendarEntry(id: String(i), start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                          declined: Self.isDeclined(e))
        }
        guard let picked = UpcomingMeeting.pick(entries, now: now), let i = Int(picked.id) else {
            next = nil; joinURL = nil; return
        }
        let event = events[i]
        next = event
        joinURL = MeetingLinks.firstJoinURL(in: [event.url?.absoluteString ?? "", event.location ?? "", event.notes ?? ""])
    }

    public func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private static func isDeclined(_ e: EKEvent) -> Bool {
        if e.status == .canceled { return true }
        return e.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined
    }

    private func observeChanges() {
        guard changeObserver == nil else { return }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
}
