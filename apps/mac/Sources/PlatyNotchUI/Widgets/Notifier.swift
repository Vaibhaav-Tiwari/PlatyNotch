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
    func schedule(id: String, title: String, body: String, at date: Date?)
    func cancel(id: String)
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
    public func schedule(id: String, title: String, body: String, at date: Date?) {}
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

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func schedule(id: String, title: String, body: String, at date: Date?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if let date {
            let interval = date.timeIntervalSinceNow
            if interval > 0 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false) }
        }
        center.add(UNNotificationRequest(identifier: Self.prefix + id, content: content, trigger: trigger))
    }

    func cancel(id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [Self.prefix + id])
        center.removeDeliveredNotifications(withIdentifiers: [Self.prefix + id])
    }

    /// An accessory app may be "active" (Settings open): still show the banner.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
