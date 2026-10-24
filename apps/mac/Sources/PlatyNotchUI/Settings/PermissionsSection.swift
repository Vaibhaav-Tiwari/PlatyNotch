import PlatyNotchKit
import SwiftUI

struct PermissionsSection: View {
    let services: SettingsServices

    var body: some View {
        SettingsPage("Permissions", subtitle: "Each one is optional. PlatyNotch asks only when you click Allow.") {
            PermissionRows(permissions: services.permissions)
            Divider()
            Button("Show the welcome guide again") { services.showOnboarding() }
        }
    }
}

/// One row per permission: why, what breaks without it, and an Allow button.
/// Shared by Settings and onboarding.
struct PermissionRows: View {
    let permissions: Permissions
    @State private var probe = WindowProbe()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionRow(
                title: "Accessibility", systemImage: "accessibility",
                why: "Reads the text of the window in front, for Memory, and lets the volume and brightness HUD take those keys.",
                withoutIt: "Memory capture stays off and the system's volume and brightness HUD shows. Everything else works.",
                state: permissions.accessibility ? .granted : .notAsked,
                allow: { [probe] in permissions.requestAccessibility(isOnScreen: { probe.isOnScreen }) },
                openSettings: { Permissions.open(.accessibility) })
            if let advice = permissions.accessibilityAdvice.text {
                Text(verbatim: advice)
                    .font(.caption)
                    .foregroundStyle(Theme.color(.attention))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
            PermissionRow(
                title: "Calendar", systemImage: "calendar",
                why: "Shows your meetings, their join links and 10, 5 and 1-minute reminders; quick add can create events.",
                withoutIt: "No meetings in the notch; quick add saves events as reminders.",
                state: state(permissions.calendar.access),
                allow: { Task { await permissions.requestCalendar() } },
                openSettings: { Permissions.open(.calendars) })
            PermissionRow(
                title: "Reminders", systemImage: "checkmark.circle",
                why: "Shows reminders due today and overdue, ticks them off, and adds new ones from quick add.",
                withoutIt: "The Reminders widget stays empty.",
                state: state(permissions.reminders.access),
                allow: { Task { await permissions.requestReminders() } },
                openSettings: { Permissions.open(.reminders) })
            VStack(alignment: .leading, spacing: 6) {
                PermissionHeader(title: "Automation", systemImage: "applescript",
                                 why: "Brings a session's terminal tab forward, controls Music and Spotify, and reads a browser's front tab when you click Add current tab.",
                                 withoutIt: "Jumping to a session only activates the app; no play/pause for those players; no Add current tab.")
                let targets = permissions.installedAutomationTargets
                if targets.isEmpty {
                    Text("None of Terminal, iTerm, Music, Spotify, Safari, Chrome or Arc is installed.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(targets, id: \.id) { t in
                    HStack {
                        Text(verbatim: t.name).frame(width: 90, alignment: .leading)
                        StateText(state: permissions.automation[t.id] ?? .notAsked)
                        Spacer()
                        if Permissions.asksFromSettings(t.id) {
                            AllowButtons(state: permissions.automation[t.id] ?? .notAsked,
                                         allow: { permissions.requestAutomation(bundleID: t.id) },
                                         openSettings: { Permissions.open(.automation) })
                        } else {
                            BrowserAutomationNote(state: permissions.automation[t.id] ?? .notAsked)
                        }
                    }
                    .padding(.leading, 28)
                }
                if permissions.anyAutomationDenied {
                    Text(verbatim: "Turned on but still refused, or macOS no longer asks? PlatyNotch was rebuilt or updated and macOS keeps the old answer. In Terminal run: \(PermissionAdvice.resetAppleEvents)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 28)
                }
            }
            PermissionRow(
                title: "Notifications", systemImage: "bell.badge",
                why: "Alerts you when an agent finishes while the notch is hidden.",
                withoutIt: "Alerts stay in the notch only.",
                state: permissions.notifications,
                allow: { permissions.requestNotifications() },
                openSettings: { Permissions.open(.notifications) })
        }
        .background(WindowReader(probe: probe))
        .onAppear { permissions.refresh() }
        // Back from System Settings: show what was just allowed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.userReturned()
        }
    }

    private func state(_ access: CalendarService.Access) -> Permissions.State {
        switch access {
        case .granted: .granted
        case .denied: .denied
        case .notAsked: .notAsked
        case .unavailable: .unavailable("Needs the installed app.")
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let systemImage: String
    let why: String
    let withoutIt: String
    let state: Permissions.State
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            PermissionHeader(title: title, systemImage: systemImage, why: why, withoutIt: withoutIt)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                StateText(state: state)
                AllowButtons(state: state, allow: allow, openSettings: openSettings)
            }
        }
    }
}

private struct PermissionHeader: View {
    let title: String
    let systemImage: String
    let why: String
    let withoutIt: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).font(.title3).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(why).font(.caption)
                Text("If denied: \(withoutIt)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StateText: View {
    let state: Permissions.State

    var body: some View {
        switch state {
        case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .denied: Label("Denied", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption)
        case .notAsked: Text("Not allowed yet").foregroundStyle(.secondary).font(.caption)
        case .unavailable(let why): Text(verbatim: why).foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// A browser's row: asked from "Add current tab" only, never from here.
private struct BrowserAutomationNote: View {
    let state: Permissions.State

    var body: some View {
        switch state {
        case .denied: Button("Open System Settings") { Permissions.open(.automation) }
        case .granted: EmptyView()
        default: Text("Asked when you click Add current tab").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AllowButtons: View {
    let state: Permissions.State
    let allow: () -> Void
    let openSettings: () -> Void

    var body: some View {
        switch state {
        case .granted: EmptyView()
        case .notAsked: Button("Allow", action: allow)
        case .denied: Button("Open System Settings", action: openSettings)
        case .unavailable: EmptyView()
        }
    }
}
