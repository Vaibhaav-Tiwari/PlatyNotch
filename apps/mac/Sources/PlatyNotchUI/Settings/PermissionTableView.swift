import CoreBluetooth
import PlatyNotchKit
import SwiftUI

/// The permission table (spec 10, step 3; Settings › Privacy & Permissions): each
/// permission, what it powers, what you lose without it, its state and one button. Nothing
/// is asked without a click, and only through the existing request paths
/// (`PermissionTable`'s actions).
struct PermissionTableView: View {
    let permissions: Permissions
    /// Opens a Settings page (camera and Bluetooth are asked from their widget's page).
    let openSettings: (String) -> Void
    /// The first run's narrower table: one line under each title.
    var compact = false
    @State private var probe = WindowProbe()

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(PermissionTable.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 48) }
                line(row)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .background(WindowReader(probe: probe))
        .onAppear { permissions.refresh() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Permissions")
    }

    static func systemImage(_ id: PermissionID) -> String {
        switch id {
        case .accessibility: "accessibility"
        case .calendars: "calendar"
        case .reminders: "checklist"
        case .automation: "applescript"
        case .camera: "camera"
        case .notifications: "bell.badge"
        case .bluetooth: "headphones"
        }
    }

    private func line(_ row: PermissionRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SymbolWell(systemImage: Self.systemImage(row.id), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title).font(.system(size: 13, weight: .semibold))
                Text(verbatim: row.powers)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    Text(verbatim: "Without it: \(row.withoutIt)")
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint(compact ? "Without it: \(row.withoutIt)" : "")
            Spacer(minLength: 8)
            control(row)
        }
        .padding(.vertical, compact ? 7 : 9)
    }

    @ViewBuilder private func control(_ row: PermissionRow) -> some View {
        let state: Permissions.State = Self.state(row.id, permissions: permissions)
        switch (state, row.action) {
        case (.granted, _):
            Label("Allowed", systemImage: "checkmark.circle.fill")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(SettingsTint.accent)
        case (.unavailable(let why), _):
            Text(verbatim: why.hasSuffix(".") ? String(why.dropLast()) : why)
                .font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 130, alignment: .trailing)
        case (.denied, .request), (_, .openSystemSettings):
            Button("Open Settings") { Self.openSystemPane(row.id) }
                .help("Opens System Settings › Privacy & Security")
        case (_, .openOwner(let section)):
            Button(row.id == .camera ? "Set up in Mirror" : "Set up in System") { openSettings(section) }
        default:
            Button("Allow") { request(row.id) }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Allow \(row.title)")
        }
    }

    /// The row's state, read without asking.
    static func state(_ id: PermissionID, permissions: Permissions) -> Permissions.State {
        switch id {
        case .accessibility: return permissions.accessibility ? .granted : .notAsked
        case .calendars: return access(permissions.calendar.access)
        case .reminders: return access(permissions.reminders.access)
        case .notifications: return permissions.notifications
        case .automation:
            if permissions.automation.values.contains(.granted) { return .granted }
            return permissions.anyAutomationDenied ? .denied : .notAsked
        case .camera:
            switch CameraAccess.system.status() {
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            default: return .notAsked
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .granted
            case .notDetermined: return .notAsked
            default: return .denied
            }
        }
    }

    private static func access(_ a: CalendarService.Access) -> Permissions.State {
        switch a {
        case .granted: .granted
        case .denied: .denied
        case .notAsked: .notAsked
        case .unavailable: .unavailable("Needs the installed app")
        }
    }

    /// The existing request for `id`, on this click only.
    private func request(_ id: PermissionID) {
        switch id {
        case .accessibility: permissions.requestAccessibility(isOnScreen: { [probe] in probe.isOnScreen })
        case .calendars: Task { await permissions.requestCalendar() }
        case .reminders: Task { await permissions.requestReminders() }
        case .notifications: permissions.requestNotifications()
        case .automation, .camera, .bluetooth: break   // never asked from the table
        }
    }

    private static func openSystemPane(_ id: PermissionID) {
        switch id {
        case .accessibility: Permissions.open(.accessibility)
        case .calendars: Permissions.open(.calendars)
        case .reminders: Permissions.open(.reminders)
        case .automation: Permissions.open(.automation)
        case .camera: Permissions.open(.camera)
        case .notifications: Permissions.open(.notifications)
        case .bluetooth: Permissions.open(.bluetooth)
        }
    }
}
