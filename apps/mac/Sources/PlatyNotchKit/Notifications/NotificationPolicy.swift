import Foundation

/// One column of Settings › Notifications.
public enum NotificationField: Sendable, CaseIterable {
    case showInPill, canOpen, quietDuringFocus
}

/// One row of Settings › Notifications (spec 6.3): whether the kind shows in the pill,
/// may open the notch by itself, and keeps quiet while a focus session runs.
public struct NotificationRule: Codable, Equatable, Sendable {
    public var showInPill: Bool
    public var canOpen: Bool
    public var quietDuringFocus: Bool

    public init(showInPill: Bool, canOpen: Bool, quietDuringFocus: Bool) {
        self.showInPill = showInPill
        self.canOpen = canOpen
        self.quietDuringFocus = quietDuringFocus
    }

    public subscript(field: NotificationField) -> Bool {
        get {
            switch field {
            case .showInPill: showInPill
            case .canOpen: canOpen
            case .quietDuringFocus: quietDuringFocus
            }
        }
        set {
            switch field {
            case .showInPill: showInPill = newValue
            case .canOpen: canOpen = newValue
            case .quietDuringFocus: quietDuringFocus = newValue
            }
        }
    }
}

/// The per-kind notification rules (spec 6.3 table, Rulings 8 and 17). Approvals are
/// locked on, always open and never quiet: nothing here can silence or hide one.
/// Saved as JSON under `key`; a kind missing from the saved value takes its default.
public struct NotificationPolicy: Codable, Equatable, Sendable {
    public static let key = "notifications.policy"

    private var rules: [NotificationKind: NotificationRule]

    public init() {
        rules = Dictionary(uniqueKeysWithValues: NotificationKind.allCases.map { ($0, Self.defaultRule($0)) })
    }

    /// Spec 6.3's defaults: (show in pill, can open, quiet during Focus).
    public static func defaultRule(_ kind: NotificationKind) -> NotificationRule {
        switch kind {
        case .approval: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: false)
        case .agentNeedsYou: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: false)
        case .agentFinished: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: true)
        case .ringing: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: false)
        case .meetingStarting: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: true)
        case .reminder: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: true)
        case .other: NotificationRule(showInPill: true, canOpen: false, quietDuringFocus: true)
        case .pluginUndeclared: NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: true)
        }
    }

    /// A kind's rule. Setting it leaves the locked cells (every approval cell) as they are.
    public subscript(kind: NotificationKind) -> NotificationRule {
        get { rules[kind] ?? Self.defaultRule(kind) }
        set {
            var rule = newValue
            let fallback = Self.defaultRule(kind)
            for field in NotificationField.allCases where Self.isLocked(kind, field) {
                rule[field] = fallback[field]
            }
            rules[kind] = rule
        }
    }

    /// Cells the user cannot change: an approval always shows, always opens and is never quiet.
    public static func isLocked(_ kind: NotificationKind, _ field: NotificationField) -> Bool {
        kind == .approval
    }

    /// Whether a `kind` may open the notch now.
    public func mayOpen(_ kind: NotificationKind, focusActive: Bool) -> Bool {
        let rule = self[kind]
        return rule.canOpen && !(rule.quietDuringFocus && focusActive)
    }

    /// Kinds the pill leaves out (never approvals).
    public var hiddenInPill: Set<NotificationKind> {
        Set(NotificationKind.allCases.filter { !self[$0].showInPill })
    }

    /// The row governing a store notice's `kind`; nil for the app's own info notices,
    /// which keep today's focus hold.
    public static func kind(noticeKind: String) -> NotificationKind? {
        switch noticeKind {
        case "session-done": .agentFinished
        case "session-failed", "approval-timeout", "needs-input": .agentNeedsYou
        default: nil
        }
    }

    // MARK: - Storage

    public static func load(from defaults: UserDefaults) -> NotificationPolicy {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(NotificationPolicy.self, from: data) else { return NotificationPolicy() }
        return saved
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public init(from decoder: Decoder) throws {
        let saved = try decoder.singleValueContainer().decode([String: NotificationRule].self)
        self.init()
        for (raw, rule) in saved {
            guard let kind = NotificationKind(rawValue: raw) else { continue }
            self[kind] = rule   // locked cells keep their fixed values
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        let byName: [String: NotificationRule] = Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) })
        try c.encode(byName)
    }
}
