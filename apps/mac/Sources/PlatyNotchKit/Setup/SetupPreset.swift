import Foundation

/// The three setups the first run offers (spec 10), also in Settings. A preset only
/// chooses which built-in widgets are on, the four glances, Minimal or Always on, and
/// whether Agents shows; plug-in widgets are never touched.
public enum SetupPreset: String, CaseIterable, Codable, Sendable {
    case everyday, developer, minimal

    /// Every built-in widget id (the ones a preset may change).
    public static let builtIns: [String] = [
        "music", "meeting", "focus", "loops", "time", "hud", "shelf", "clipboard", "reminders", "weather",
        "wellbeing", "system", "games", "launch", "baskets", "fileActions", "mail", "notes", "mirror", "snap",
    ]

    private static let everydayOn = ["music", "meeting", "time", "weather", "shelf", "clipboard"]

    public var title: String {
        switch self {
        case .everyday: "Everyday"
        case .developer: "Developer"
        case .minimal: "Minimal"
        }
    }

    /// One line under the card's title.
    public var summary: String {
        switch self {
        case .everyday: "Music, meetings, timers, weather, shelf and clipboard."
        case .developer: "Everyday plus agents, usage limits, file actions and snapping."
        case .minimal: "The notch stays hidden until something is live."
        }
    }

    public var turnsOn: [String] {
        switch self {
        case .everyday: Self.everydayOn
        case .developer: Self.everydayOn + ["fileActions", "snap"]
        case .minimal: ["music"]
        }
    }

    public var turnsOff: [String] {
        switch self {
        case .everyday: ["fileActions", "snap"]
        case .developer: []
        case .minimal: Self.builtIns.filter { $0 != "music" }
        }
    }

    public var glances: [String] {
        switch self {
        case .everyday: ["meeting", "weather", "system", "loops"]
        case .developer: ["meeting", GlanceSlots.usageID, "weather", "system"]
        case .minimal: [GlanceSlots.usageID]
        }
    }

    public var mode: AppearanceSettings.Mode { self == .minimal ? .minimal : .alwaysOn }

    /// Whether the preset turns Agents on before an agent connects.
    public var showsAgents: Bool { self != .everyday }
}

/// What applying a preset changes from what is on now: only real changes are listed.
public struct PresetChange: Equatable, Sendable {
    public let turnOn: [String]
    public let turnOff: [String]

    public init(turnOn: [String], turnOff: [String]) {
        self.turnOn = turnOn
        self.turnOff = turnOff
    }

    /// Turning anything off asks first (spec 14); turning things on does not.
    public var needsConfirmation: Bool { !turnOff.isEmpty }

    public static func plan(_ p: SetupPreset, enabled: Set<String>) -> PresetChange {
        PresetChange(turnOn: p.turnsOn.filter { !enabled.contains($0) },
                     turnOff: p.turnsOff.filter { enabled.contains($0) })
    }
}

/// Everything applying a preset would change now: widgets on and off, the four glances
/// and the notch mode. Applying from Settings (or the first run replayed from there)
/// always asks with this summary; only a new install's first run applies directly.
public struct PresetPlan: Equatable, Sendable {
    public let preset: SetupPreset
    public let turnOn: [String]
    public let turnOff: [String]
    /// The new glances, or nil when they are already the preset's.
    public let glances: [String]?
    /// The new mode, or nil when it is already the preset's.
    public let mode: AppearanceSettings.Mode?

    public init(preset: SetupPreset, turnOn: [String], turnOff: [String], glances: [String]?,
                mode: AppearanceSettings.Mode?) {
        self.preset = preset
        self.turnOn = turnOn
        self.turnOff = turnOff
        self.glances = glances
        self.mode = mode
    }

    public static func plan(_ p: SetupPreset, enabled: Set<String>, glances: [String],
                            mode: AppearanceSettings.Mode) -> PresetPlan {
        let change = PresetChange.plan(p, enabled: enabled)
        return PresetPlan(preset: p, turnOn: change.turnOn, turnOff: change.turnOff,
                          glances: glances == p.glances ? nil : p.glances, mode: mode == p.mode ? nil : p.mode)
    }

    /// Nothing would change: this preset is the current setup.
    public var isCurrent: Bool { turnOn.isEmpty && turnOff.isEmpty && glances == nil && mode == nil }

    /// Whether to ask first: always, except in a new install's first run or when nothing changes.
    public func asks(firstRun: Bool) -> Bool { !firstRun && !isCurrent }

    /// One line per kind of change, in plain words; `title` names a widget or glance id.
    public func summary(title: (String) -> String) -> [String] {
        var lines: [String] = []
        if !turnOn.isEmpty { lines.append("Turns on " + turnOn.map(title).joined(separator: ", ") + ".") }
        if !turnOff.isEmpty { lines.append("Turns off " + turnOff.map(title).joined(separator: ", ") + ".") }
        if let glances { lines.append("Glances become " + glances.map(title).joined(separator: ", ") + ".") }
        if let mode {
            lines.append(mode == .minimal ? "The notch hides until something is live." : "The notch stays on.")
        }
        return lines
    }
}

extension FirstRunState {
    /// Launch: who gets the first run or the tour card, before any widget starts (spec 10,
    /// 14). A new install is marked pending (a layout saved during its first launches never
    /// makes it an existing user) and needs no upgrade; anyone else gets `UpgradeMigration`
    /// once. `layoutSaved`: a widget layout was saved before this launch.
    public static func prepare(defaults: UserDefaults, onboardingDone: Bool, layoutSaved: Bool,
                               glanceCapable: [String]) -> FirstRunState {
        let state = resolve(onboardingDone: onboardingDone, layoutSaved: layoutSaved, defaults: defaults)
        if state == .firstRun {
            defaults.set(true, forKey: pendingKey)
            defaults.set(true, forKey: UpgradeMigration.key)
        }
        UpgradeMigration.run(defaults: defaults, existingUser: state != .firstRun, glanceCapable: glanceCapable)
        return state
    }

    /// The first run (or the tour) ended: seen, the tour card no longer offered.
    public static func finish(defaults: UserDefaults) {
        defaults.set(true, forKey: tourOfferedKey)
        defaults.removeObject(forKey: pendingKey)
    }
}
