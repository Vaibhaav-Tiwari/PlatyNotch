import AppKit
import ApplicationServices
import AVFoundation
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

    /// Apps PlatyNotch scripts with Apple Events: terminals (jump to a session's tab),
    /// music players (now playing controls), browsers ("Add current tab", Task 11) and
    /// Mail (the v0.2 Mail widget).
    static let automationTargets: [(id: String, name: String)] = [
        (TerminalApps.appleTerminalID, "Terminal"), (TerminalApps.iTermID, "iTerm"),
        ("com.apple.Music", "Music"), ("com.spotify.client", "Spotify"),
    ] + SupportedBrowser.allCases.map { ($0.rawValue, $0.name) } + [(MailSystem.mailID, "Mail")]

    /// Browsers are asked only from "Add current tab" and Mail only from the Mail widget's
    /// Allow button (the one place each Automation prompt may appear), so Settings shows
    /// their status without an Allow button.
    static func asksFromSettings(_ bundleID: String) -> Bool {
        SupportedBrowser(rawValue: bundleID) == nil && bundleID != MailSystem.mailID
    }

    /// Whether Settings › Permissions lists `bundleID`'s Automation row: Mail only while
    /// the Mail widget is on.
    static func listsAutomation(_ bundleID: String, mailWidgetOn: Bool) -> Bool {
        bundleID != MailSystem.mailID || mailWidgetOn
    }

    /// The status a row shows. Rows without an Allow button never say "allow": an app
    /// that is not running reads as such.
    static func shownState(_ state: State, bundleID: String, name: String) -> State {
        guard !asksFromSettings(bundleID), case .unavailable = state else { return state }
        return .unavailable("Shown when \(name) is open")
    }

    /// Where an app without an Allow button in Settings is asked from.
    static func askedFrom(_ bundleID: String) -> String {
        bundleID == MailSystem.mailID ? "Asked from the Mail widget's Allow button" : "Asked when you click Add current tab"
    }

    private(set) var accessibility = false
    /// What to add while Accessibility is off: definite after a grant to another build,
    /// conditional after Allow and coming back (feedback 7).
    private(set) var accessibilityAdvice: PermissionAdvice.AccessibilityAdvice = .none
    @ObservationIgnored private var allowReturn = AllowReturn()
    @ObservationIgnored private let trust: AccessibilityTrust
    /// The bounded recheck after Allow (a new click replaces it).
    @ObservationIgnored private(set) var accessibilityPoll: Task<Void, Never>?
    private(set) var notifications: State = .notAsked
    private(set) var automation: [String: State] = [:]
    /// Camera (v0.2 mirror). Read without prompting; asked only from a button
    /// (`requestCamera`).
    private(set) var camera: State = .notAsked
    @ObservationIgnored private let cameraAccess: CameraAccess
    /// This build's camera grant (`GrantStamp`): a mirror that was on resumes after a
    /// rebuild only when the grant was made to this build ("Turn On Again" otherwise).
    @ObservationIgnored let cameraGrant: GrantStamp
    let calendar: CalendarService
    let reminders: RemindersService

    static let cameraGrantKey = "camera.grant"

    init(calendar: CalendarService, reminders: RemindersService, trust: AccessibilityTrust = .system,
         camera: CameraAccess = .system, cameraGrant: GrantStamp = CodeIdentity.stamp(key: Permissions.cameraGrantKey)) {
        self.calendar = calendar
        self.reminders = reminders
        self.trust = trust
        cameraAccess = camera
        self.cameraGrant = cameraGrant
    }

    /// Re-reads every status without prompting.
    func refresh() {
        readAccessibility()
        calendar.refreshAccess()
        reminders.refreshAccess()
        refreshNotifications()
        readCamera()
        for id in automationTargetsToRead() {
            Task.detached {
                let s = Self.automationStatus(bundleID: id, ask: false)
                await MainActor.run { self.automation[id] = s }
            }
        }
    }

    /// Whether the Mail widget is on (the app's registry; Settings sets it). While it is
    /// off Mail's status is never read.
    @ObservationIgnored var mailWidgetOn: @MainActor () -> Bool = { false }

    /// The Automation targets `refresh` reads: installed ones, Mail only while its widget is on.
    func automationTargetsToRead(installed: [String]? = nil) -> [String] {
        (installed ?? installedAutomationTargets.map(\.id))
            .filter { Self.listsAutomation($0, mailWidgetOn: mailWidgetOn()) }
    }

    var installedAutomationTargets: [(id: String, name: String)] {
        Self.automationTargets.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    // MARK: - Accessibility (memory capture)

    /// Shows the system Accessibility prompt. Only from the "Allow" button for capture.
    /// `isOnScreen`: the Settings / onboarding window is visible and not covered; the
    /// follow-up reads happen only then.
    func requestAccessibility(isOnScreen: @escaping @MainActor () -> Bool = { true }) {
        allowReturn.allowClicked()
        trust.request()
        accessibility = trust.isTrusted()
        // The grant happens in System Settings; poll briefly so the row updates.
        accessibilityPoll?.cancel()
        accessibilityPoll = Task { [weak self] in
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard isOnScreen() else { continue }
                self.readAccessibility()
                if self.accessibility { return }
            }
        }
    }

    /// PlatyNotch went to the background (System Settings or another app in front).
    func userLeft() { allowReturn.appResigned() }

    /// Back in PlatyNotch after Allow and a visit elsewhere: a still-missing trust gets the
    /// conditional advice.
    func userReturned() {
        allowReturn.appBecameActive()
        refresh()
    }

    /// Reads trust (never prompts), stamps a working grant with this build, and decides
    /// whether the "remove and allow again" advice applies.
    private func readAccessibility() {
        let trusted = trust.isTrusted()
        let defaults = UserDefaults.standard
        if trusted { AccessibilityGrant.note(defaults, identity: CodeIdentity.current) }
        let history = AccessibilityGrant.history(defaults, identity: CodeIdentity.current)
        let advice = PermissionAdvice.accessibility(trusted: trusted, returnedAfterAllow: allowReturn.returned,
                                                    history: history)
        if accessibility != trusted { accessibility = trusted }
        if accessibilityAdvice != advice { accessibilityAdvice = advice }
    }

    /// Some Automation target refused PlatyNotch: the rebuilt-app note applies.
    var anyAutomationDenied: Bool { automation.values.contains(.denied) }

    // MARK: - Calendar

    func requestCalendar() async {
        await calendar.requestAccess()
    }

    // MARK: - Reminders

    func requestReminders() async {
        await reminders.requestAccess()
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

    // MARK: - Camera (v0.2 mirror)

    /// Shows the system camera prompt. Only from a button (the mirror's, or Settings).
    func requestCamera() async {
        _ = await cameraAccess.request()
        readCamera()
    }

    /// Reads the camera status (never prompts) and stamps a working grant with this build.
    func readCamera() {
        let s = Self.cameraState(cameraAccess.status())
        if s == .granted { cameraGrant.note() }
        if camera != s { camera = s }
    }

    nonisolated static func cameraState(_ status: AVAuthorizationStatus) -> State {
        switch status {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .unavailable("Restricted on this Mac.")
        case .notDetermined: .notAsked
        @unknown default: .notAsked
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
        case reminders = "Privacy_Reminders"
        case automation = "Privacy_Automation"
        case camera = "Privacy_Camera"
        case notifications = "notifications"
        /// Opened from the System widget's settings only (no Allow row: its button there
        /// is the only place the Bluetooth prompt can appear).
        case bluetooth = "Privacy_Bluetooth"
        /// Files and Folders (the downloads sub-feature), for the same reason.
        case filesAndFolders = "Privacy_FilesAndFolders"
    }

    static func open(_ pane: Pane) {
        let url = pane == .notifications
            ? URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
            : URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)")!
        NSWorkspace.shared.open(url)
    }
}

/// Camera authorization (a seam: tests and smoke runs never prompt or touch the camera).
/// Reading the status never prompts and never turns the camera on.
struct CameraAccess: Sendable {
    var status: @Sendable () -> AVAuthorizationStatus
    var request: @Sendable () async -> Bool

    static let system = CameraAccess(
        status: { AVCaptureDevice.authorizationStatus(for: .video) },
        // An explicit continuation, not the compiler's async form of this completion-handler
        // API: the generated form of AVAssetWriter.finishWriting crashed on resume on macOS
        // 15.7 (CI), and this AVFoundation call is not proven safe there.
        request: {
            await withCheckedContinuation { done in
                AVCaptureDevice.requestAccess(for: .video) { done.resume(returning: $0) }
            }
        })
}
