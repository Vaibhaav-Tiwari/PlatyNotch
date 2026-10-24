import Foundation
@preconcurrency import UserNotifications

/// System notifications for widgets (timer done, alarm backup, reminders).
/// Ids are namespaced by the caller (e.g. "timer:3"); scheduling an existing id replaces it.
@MainActor
public protocol Notifier: AnyObject {
    /// False when notifications cannot work here (an unbundled `swift run` build).
    var isAvailable: Bool { get }
    /// Asks for permission (only call when the user enables a widget that needs it).
    func requestAuthorization() async -> Bool
    /// Shows now when `date` is nil, else at `date` (also when the app is not running).
    /// True once Notification Center accepted the request (false e.g. before permission).
    @discardableResult
    func schedule(id: String, title: String, body: String, at date: Date?) async -> Bool
    /// At a wall-clock time (`UNCalendarNotificationTrigger`; alarms), also when the app is
    /// not running. The components are read in the user's current calendar and time zone.
    @discardableResult
    func schedule(id: String, title: String, body: String, matching components: DateComponents) async -> Bool
    func cancel(id: String)
}

extension Notifier {
    /// Notifiers without calendar triggers use the date the components name.
    @discardableResult
    public func schedule(id: String, title: String, body: String, matching components: DateComponents) async -> Bool {
        await schedule(id: id, title: title, body: body, at: Calendar.current.date(from: components))
    }
}

public enum Notifiers {
    /// The system notifier when bundled, else a no-op (Notification Center needs a bundle).
    @MainActor public static func make() -> Notifier {
        Permissions.canUseNotifications ? SystemNotifier() : NoopNotifier()
    }
}

/// Used when the app is not bundled: does nothing.
@MainActor
public final class NoopNotifier: Notifier {
    public init() {}
    public var isAvailable: Bool { false }
    public func requestAuthorization() async -> Bool { false }
    public func schedule(id: String, title: String, body: String, at date: Date?) async -> Bool { false }
    public func schedule(id: String, title: String, body: String, matching components: DateComponents) async -> Bool { false }
    public func cancel(id: String) {}
}

/// `UNUserNotificationCenter`; only created for a bundled app.
@MainActor
final class SystemNotifier: NSObject, Notifier, UNUserNotificationCenterDelegate {
    static let prefix = "dev.platynotch.widget."
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    var isAvailable: Bool { true }

    // Every call is guarded by `Permissions.canUseNotifications` (Notification Center
    // traps without a bundle), although only a bundled app creates this notifier.

    func requestAuthorization() async -> Bool {
        guard Permissions.canUseNotifications else { return false }
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(id: String, title: String, body: String, at date: Date?) async -> Bool {
        var trigger: UNNotificationTrigger?
        if let date {
            let interval = date.timeIntervalSinceNow
            if interval > 0 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false) }
        }
        return await add(id: id, title: title, body: body, trigger: trigger)
    }

    func schedule(id: String, title: String, body: String, matching components: DateComponents) async -> Bool {
        await add(id: id, title: title, body: body,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }

    /// False (nothing added) unless notifications are allowed: a request added before the
    /// user answers the permission prompt may never be delivered, so callers retry later.
    private func add(id: String, title: String, body: String, trigger: UNNotificationTrigger?) async -> Bool {
        guard Permissions.canUseNotifications else { return false }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        default: return false
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: Self.prefix + id, content: content, trigger: trigger)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    func cancel(id: String) {
        guard Permissions.canUseNotifications else { return }
        center.removePendingNotificationRequests(withIdentifiers: [Self.prefix + id])
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
    }

    /// An accessory app may be "active" (Settings open): still show the banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
