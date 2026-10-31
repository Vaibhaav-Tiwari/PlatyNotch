import Foundation

/// The three setups the first run offers (spec 10), also in Settings. A preset only
/// chooses which built-in widgets are on, Minimal or Always on, and
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
        case .everyday: "Music, meetings, timers, weather, notes, reminders, shelf, clipboard and games."
        case .developer: "Everyday plus agents, usage limits, file actions and snapping."
        case .minimal: "Music and weather; the notch stays hidden until something is live."
        }
    }

    /// The widgets on, including every one its dock's tools need (Island: a fresh setup
    /// never shows a dimmed "Turn on" slot; access such as Reminders' is asked in the tool).
    public var turnsOn: [String] {
        switch self {
        case .everyday: Self.everydayOn + ["notes", "reminders", "games"]
        case .developer: Self.everydayOn + ["notes", "reminders", "fileActions", "snap"]
        case .minimal: ["music", "weather"]
        }
    }

    public var turnsOff: [String] {
        switch self {
        case .everyday: ["fileActions", "snap"]
        case .developer: []
        case .minimal: Self.builtIns.filter { $0 != "music" && $0 != "weather" }
        }
    }

    public var mode: AppearanceSettings.Mode { self == .minimal ? .minimal : .alwaysOn }

    /// Whether the preset shows Agents before an agent connects (`AgentsTabRule.always`).
    public var showsAgents: Bool { layout.prefs.agentsTab == .always }
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

/// Everything applying a preset would change now: widgets on and off, the notch mode, the
/// dock and the Island choices (pill order, folded dock, Agents tab). Applying from Settings (or the first run replayed from there)
/// always asks with this summary; only a new install's first run applies directly.
public struct PresetPlan: Equatable, Sendable {
    public let preset: SetupPreset
    public let turnOn: [String]
    public let turnOff: [String]
    /// The new mode, or nil when it is already the preset's.
    public let mode: AppearanceSettings.Mode?
    /// The new dock, or nil when it is already the preset's.
    public let dock: DockLayout?
    /// The new Island choices, or nil when they are already the preset's.
    public let prefs: IslandPrefs?
    /// The Island choices before (what the summary compares with).
    private let currentPrefs: IslandPrefs

    public init(preset: SetupPreset, turnOn: [String], turnOff: [String],
                mode: AppearanceSettings.Mode?, dock: DockLayout? = nil, prefs: IslandPrefs? = nil,
                currentPrefs: IslandPrefs = IslandPrefs()) {
        self.preset = preset
        self.turnOn = turnOn
        self.turnOff = turnOff
        self.mode = mode
        self.dock = dock
        self.prefs = prefs
        self.currentPrefs = currentPrefs
    }

    /// Widgets and mode only (the dock and Island choices taken as already the preset's).
    public static func plan(_ p: SetupPreset, enabled: Set<String>,
                            mode: AppearanceSettings.Mode) -> PresetPlan {
        plan(p, enabled: enabled, mode: mode, dock: p.layout.dock, prefs: p.layout.prefs)
    }

    /// `dock` and `prefs` are the current ones.
    public static func plan(_ p: SetupPreset, enabled: Set<String>, mode: AppearanceSettings.Mode,
                            dock: DockLayout, prefs: IslandPrefs) -> PresetPlan {
        let change = PresetChange.plan(p, enabled: enabled)
        let layout = p.layout
        return PresetPlan(preset: p, turnOn: change.turnOn, turnOff: change.turnOff,
                          mode: mode == p.mode ? nil : p.mode,
                          dock: dock == layout.dock ? nil : layout.dock,
                          prefs: prefs == layout.prefs ? nil : layout.prefs,
                          currentPrefs: prefs)
    }

    /// Nothing would change: this preset is the current setup.
    public var isCurrent: Bool { turnOn.isEmpty && turnOff.isEmpty && mode == nil && dock == nil && prefs == nil }

    /// Whether to ask first: always, except in a new install's first run or when nothing changes.
    public func asks(firstRun: Bool) -> Bool { !firstRun && !isCurrent }

    /// One line per kind of change, in plain words; `title` names a widget id.
    public func summary(title: (String) -> String) -> [String] {
        var lines: [String] = []
        if !turnOn.isEmpty { lines.append("Turns on " + turnOn.map(title).joined(separator: ", ") + ".") }
        if !turnOff.isEmpty { lines.append("Turns off " + turnOff.map(title).joined(separator: ", ") + ".") }
        if let mode {
            lines.append(mode == .minimal ? "The notch hides until something is live." : "The notch stays on.")
        }
        if let dock {
            let titles: [String] = dock.slots.compactMap { slot in
                switch slot {
                case .core(.search): nil
                case .core(let t): t.title
                case .tool(let id): title(id)
                }
            }
            lines.append("Dock: " + titles.joined(separator: ", ") + ".")
        }
        if let prefs {
            if prefs.dockFolded != currentPrefs.dockFolded {
                lines.append(prefs.dockFolded ? "The dock folds into Search." : "The dock shows every tool.")
            }
            if prefs.pillOrder != currentPrefs.pillOrder {
                lines.append(prefs.pillOrder == .agentsFirst ? "The pill shows agents first." : "The pill shows music first.")
            }
            if prefs.agentsTab != currentPrefs.agentsTab {
                lines.append(prefs.agentsTab == .always ? "Agents shows in the panel."
                                                        : "Agents shows once an agent's hooks are set up.")
            }
        }
        return lines
    }
}

extension FirstRunState {
    /// Launch: who gets the first run or the tour card, before any widget starts (spec 10,
    /// 14). A new install is marked pending (a layout saved during its first launches never
    /// makes it an existing user) and needs no upgrade; anyone else gets `UpgradeMigration`
    /// `QuietNotchMigration` and `IslandMigration` once. `layoutSaved`: a widget layout was saved before this launch.
    public static func prepare(defaults: UserDefaults, onboardingDone: Bool, layoutSaved: Bool) -> FirstRunState {
        let state = resolve(onboardingDone: onboardingDone, layoutSaved: layoutSaved, defaults: defaults)
        if state == .firstRun {
            defaults.set(true, forKey: pendingKey)
            defaults.set(true, forKey: UpgradeMigration.key)
            defaults.set(true, forKey: QuietNotchMigration.key)
            defaults.set(true, forKey: IslandMigration.key)
        }
        UpgradeMigration.run(defaults: defaults, existingUser: state != .firstRun)
        QuietNotchMigration.run(defaults: defaults, existingUser: state != .firstRun)
        IslandMigration.run(defaults: defaults, existingUser: state != .firstRun)
        return state
    }

    /// The first run (or the tour) ended: seen, the tour card no longer offered.
    public static func finish(defaults: UserDefaults) {
        defaults.set(true, forKey: tourOfferedKey)
        defaults.removeObject(forKey: pendingKey)
    }
}
