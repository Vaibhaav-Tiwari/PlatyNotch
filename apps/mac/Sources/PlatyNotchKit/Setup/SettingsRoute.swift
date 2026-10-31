import Foundation

/// The Settings window's built-in pages (spec 11).
public enum SettingsPage: String, CaseIterable, Sendable {
    case general, notch, home, notifications, widgets, agents, memory, privacy, about

    public var title: String {
        switch self {
        case .general: "General"
        case .notch: "Notch"
        case .home: "Home"
        case .notifications: "Notifications"
        case .widgets: "Widgets"
        case .agents: "Agents"
        case .memory: "Memory"
        case .privacy: "Privacy & Permissions"
        case .about: "About"
        }
    }

    /// The sidebar's SF Symbol.
    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .notch: "menubar.rectangle"
        case .home: "house"
        case .notifications: "bell.badge"
        case .widgets: "square.grid.2x2"
        case .agents: "terminal"
        case .memory: "brain"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

/// Where a Settings link lands: a page and, inside it, a detail (a widget's page, an
/// Agents sub-page). Old section ids map to their new homes (Ruling 12).
public struct SettingsTarget: Equatable, Sendable {
    public var section: String
    public var detail: String?

    public init(section: String, detail: String? = nil) {
        self.section = section
        self.detail = detail
    }

    /// `now` → Home, `appearance` → Notch, `permissions` → Privacy & Permissions, `approvals` and
    /// `policy` → Agents' sub-pages, "<page>/<detail>" → that detail; nil or empty →
    /// General; anything else (a plug-in's section) passes through.
    public static func resolve(_ id: String?) -> SettingsTarget {
        guard let id, !id.isEmpty else { return SettingsTarget(section: SettingsPage.general.rawValue) }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        let head: String = parts[0]
        let detail: String? = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        switch head.lowercased() {
        case "now": return SettingsTarget(section: SettingsPage.home.rawValue, detail: detail)
        case "appearance": return SettingsTarget(section: SettingsPage.notch.rawValue, detail: detail)
        case "permissions": return SettingsTarget(section: SettingsPage.privacy.rawValue, detail: detail)
        case "approvals": return SettingsTarget(section: SettingsPage.agents.rawValue, detail: "approvals")
        case "policy": return SettingsTarget(section: SettingsPage.agents.rawValue, detail: "policy")
        default:
            let known: Bool = SettingsPage(rawValue: head.lowercased()) != nil
            return SettingsTarget(section: known ? head.lowercased() : head, detail: detail)
        }
    }
}
