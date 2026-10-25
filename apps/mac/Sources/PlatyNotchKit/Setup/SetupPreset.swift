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
