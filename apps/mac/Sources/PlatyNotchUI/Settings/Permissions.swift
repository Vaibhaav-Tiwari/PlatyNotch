import AppKit
import ApplicationServices
import CoreServices
import Observation
import PlatyNotchKit
@preconcurrency import UserNotifications

/// macOS permissions PlatyNotch can use. Reading a status never prompts; each prompt
/// happens only from its own button (onboarding or Settings › Permissions).
@MainActor @Observable
final class Permissions {
    enum State: Equatable {
        case granted, denied, notAsked, unavailable(String)
    }

    /// Apps PlatyNotch scripts with Apple Events: terminals (jump to a session's tab)
    /// and music players (now playing controls).
    static let automationTargets: [(id: String, name: String)] = [
        (TerminalApps.appleTerminalID, "Terminal"), (TerminalApps.iTermID, "iTerm"),
        ("com.apple.Music", "Music"), ("com.spotify.client", "Spotify"),
    ]

    private(set) var accessibility = false
    private(set) var notifications: State = .notAsked
    private(set) var automation: [String: State] = [:]
    let calendar: CalendarService

    init(calendar: CalendarService) {
        self.calendar = calendar
    }

    /// Re-reads every status without prompting.
    func refresh() {
        accessibility = AXIsProcessTrusted()
        calendar.refreshAccess()
        refreshNotifications()
        for t in installedAutomationTargets {
            let id = t.id
            Task.detached {
                let s = Self.automationStatus(bundleID: id, ask: false)
                await MainActor.run { self.automation[id] = s }
            }
        }
    }

    var installedAutomationTargets: [(id: String, name: String)] {
        Self.automationTargets.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    // MARK: - Accessibility (memory capture)

    /// Shows the system Accessibility prompt. Only from the "Allow" button for capture.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        // The grant happens in System Settings; poll briefly so the row updates.
        Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.accessibility = AXIsProcessTrusted()
                if self.accessibility { return }
            }
        }
    }

    // MARK: - Calendar

    func requestCalendar() async {
        await calendar.requestAccess()
    }

    // MARK: - Automation

    func requestAutomation(bundleID: String) {
        Task.detached {
            let s = Self.automationStatus(bundleID: bundleID, ask: true)
            await MainActor.run { self.automation[bundleID] = s }
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` (blocks; never call on the main thread).
    nonisolated static func automationStatus(bundleID: String, ask: Bool) -> State {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let made = bytes.withUnsafeBufferPointer {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target)
        }
        guard made == noErr else { return .unavailable("Cannot address \(bundleID).") }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                           AEEventID(typeWildCard), ask)
        switch Int(status) {
        case Int(noErr): return .granted
        case Int(errAEEventNotPermitted): return .denied
        case Int(errAEEventWouldRequireUserConsent): return .notAsked
        case Int(procNotFound): return .unavailable("Open the app first, then allow.")
        default: return .unavailable("Not available (\(status)).")
        }
    }

    // MARK: - Notifications

    /// Notification Center needs a bundled app (`swift run` has no bundle identity).
    /// Also picks the widgets' notifier (`Notifiers.make`).
    nonisolated static var canUseNotifications: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var canUseNotifications: Bool { Self.canUseNotifications }

    private func refreshNotifications() {
        guard canUseNotifications else { notifications = .unavailable("Needs the installed app."); return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let s: State = switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: .granted
            case .denied: .denied
            default: .notAsked
            }
            Task { @MainActor in self.notifications = s }
        }
    }

    func requestNotifications() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshNotifications() }
        }
    }

    // MARK: - System Settings

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case calendars = "Privacy_Calendars"
        case automation = "Privacy_Automation"
        case notifications = "notifications"
    }

    static func open(_ pane: Pane) {
        let url = pane == .notifications
            ? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            : URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}
