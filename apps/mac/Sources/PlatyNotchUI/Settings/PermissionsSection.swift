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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionRow(
                title: "Accessibility", systemImage: "accessibility",
                why: "Reads the text of the window in front, for Memory.",
                withoutIt: "Memory capture stays off. Everything else works.",
                state: permissions.accessibility ? .granted : .notAsked,
                allow: { permissions.requestAccessibility() },
                openSettings: { Permissions.open(.accessibility) })
            PermissionRow(
                title: "Calendar", systemImage: "calendar",
                why: "Shows your next meeting and its join link in the Today tab.",
                withoutIt: "No next meeting in the notch.",
                state: calendarState,
                allow: { Task { await permissions.requestCalendar() } },
                openSettings: { Permissions.open(.calendars) })
            VStack(alignment: .leading, spacing: 6) {
                PermissionHeader(title: "Automation", systemImage: "applescript",
                                 why: "Brings a session's terminal tab forward and controls Music and Spotify.",
                                 withoutIt: "Jumping to a session only activates the app; no play/pause for those players.")
                let targets = permissions.installedAutomationTargets
                if targets.isEmpty {
                    Text("None of Terminal, iTerm, Music or Spotify is installed.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(targets, id: \.id) { t in
                    HStack {
                        Text(verbatim: t.name).frame(width: 90, alignment: .leading)
                        StateText(state: permissions.automation[t.id] ?? .notAsked)
                        Spacer()
                        AllowButtons(state: permissions.automation[t.id] ?? .notAsked,
                                     allow: { permissions.requestAutomation(bundleID: t.id) },
                                     openSettings: { Permissions.open(.automation) })
                    }
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
        .onAppear { permissions.refresh() }
    }

    private var calendarState: Permissions.State {
        switch permissions.calendar.access {
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
