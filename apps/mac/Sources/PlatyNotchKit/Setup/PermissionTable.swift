import Foundation

/// The macOS permissions PlatyNotch can use (spec 10, step 3).
public enum PermissionID: String, CaseIterable, Sendable {
    case accessibility, calendars, reminders, automation, camera, notifications, bluetooth
}

/// What a row's button does. Nothing here creates a new place a prompt can come from:
/// `.request` is the existing request on a click; camera and Bluetooth are asked only from
/// their widget's own setting; Automation is asked by macOS when an app is first scripted.
public enum PermissionAction: Equatable, Sendable {
    case request
    /// Opens the Settings page that owns the prompt (e.g. "widgets/mirror").
    case openOwner(settingsSection: String)
    case openSystemSettings
}

/// One row of the permission table: what it powers and what you lose without it.
public struct PermissionRow: Identifiable, Equatable, Sendable {
    public let id: PermissionID
    public let title: String
    public let powers: String
    public let withoutIt: String
    public let action: PermissionAction

    public init(id: PermissionID, title: String, powers: String, withoutIt: String, action: PermissionAction) {
        self.id = id
        self.title = title
        self.powers = powers
        self.withoutIt = withoutIt
        self.action = action
    }
}

/// The table in the first run and in Settings › Privacy & Permissions. Every permission
/// is optional.
public enum PermissionTable {
    public static let rows: [PermissionRow] = [
        PermissionRow(id: .accessibility, title: "Accessibility",
                      powers: "Memory capture and the volume and brightness HUD",
                      withoutIt: "Memory stays off and the system HUD shows", action: .request),
        PermissionRow(id: .calendars, title: "Calendar",
                      powers: "Next meeting, Join buttons and meeting reminders",
                      withoutIt: "No meetings in Up next or the pill", action: .request),
        PermissionRow(id: .reminders, title: "Reminders",
                      powers: "Reminders due today, ticked off from the notch",
                      withoutIt: "The Reminders widget stays empty", action: .request),
        PermissionRow(id: .automation, title: "Automation",
                      powers: "Jump to an agent's terminal tab; play and pause Music and Spotify",
                      withoutIt: "Jumping only brings the app forward", action: .openSystemSettings),
        PermissionRow(id: .camera, title: "Camera",
                      powers: "The Mirror widget",
                      withoutIt: "No mirror; nothing else uses the camera",
                      action: .openOwner(settingsSection: "widgets/mirror")),
        PermissionRow(id: .notifications, title: "Notifications",
                      powers: "Alerts when an agent finishes while the notch is hidden",
                      withoutIt: "Alerts stay in the notch", action: .request),
        PermissionRow(id: .bluetooth, title: "Bluetooth",
                      powers: "AirPods battery and the connect peek",
                      withoutIt: "No headphone battery or connect peek",
                      action: .openOwner(settingsSection: "widgets/system")),
    ]

    public static func row(_ id: PermissionID) -> PermissionRow {
        rows.first { $0.id == id }!   // every id has a row (PermissionTableTests)
    }
}
