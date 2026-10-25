import Foundation

/// How an agent is recognised at a glance (user change: agent icons and usage chips):
/// its own installed Mac app's icon when one of `appBundleIDs` is installed (read at run
/// time from the user's Mac, never bundled), else a two-letter monogram on the agent's
/// colour.
public struct AgentBrand: Hashable, Sendable {
    /// One key per known agent ("claude", "codex", …), else the lowercased agent id.
    public let key: String
    public let identity: AgentIdentity
    /// "Cl", "Cx", "Cu", "Ge", "OC", "Qw", else the agent name's first two letters.
    public let monogram: String
    /// The fixed allowlist of app bundle ids whose icon may stand for this agent, in order.
    public let appBundleIDs: [String]

    public init(agent: String, agentName: String = "") {
        let id = agent.lowercased()
        identity = AgentIdentity(agent: agent)
        switch id {
        case "claude-code", "claude":
            key = "claude"; monogram = "Cl"; appBundleIDs = ["com.anthropic.claudefordesktop"]
        case "codex":
            key = "codex"; monogram = "Cx"; appBundleIDs = ["com.openai.codex", "com.openai.chat"]
        case "cursor", "cursor-agent":
            key = "cursor"; monogram = "Cu"; appBundleIDs = ["com.todesktop.230313mzl4w4u92"]
        case "gemini", "gemini-cli":
            key = "gemini"; monogram = "Ge"; appBundleIDs = []
        case "opencode":
            key = "opencode"; monogram = "OC"; appBundleIDs = []
        case "qwen", "qwen-code":
            key = "qwen"; monogram = "Qw"; appBundleIDs = []
        default:
            key = id; monogram = Self.letters(agentName.isEmpty ? agent : agentName); appBundleIDs = []
        }
    }

    /// The first two letters ("Aider" → "Ai"); "Ag" when there are none.
    static func letters(_ name: String) -> String {
        let letters = name.unicodeScalars.filter { CharacterSet.letters.contains($0) }.prefix(2).map(String.init)
        guard let first = letters.first else { return "Ag" }
        return first.uppercased() + (letters.dropFirst().first?.lowercased() ?? "")
    }

    /// The monogram tile's colour.
    public func background(dark: Bool) -> RGB { identity.rgb(dark: dark) }

    /// White or black, whichever contrasts more with the tile (both checked to 4.5:1).
    public func ink(dark: Bool) -> MonogramInk { MonogramInk.on(background(dark: dark)) }
}

/// The monogram's text colour.
public enum MonogramInk: Sendable {
    case white, black

    public var rgb: RGB { self == .white ? RGB(hex: 0xFFFFFF) : RGB(hex: 0x000000) }

    public static func on(_ background: RGB) -> MonogramInk {
        let white: Double = RGB.contrast(background, MonogramInk.white.rgb)
        let black: Double = RGB.contrast(background, MonogramInk.black.rgb)
        return white >= black ? .white : .black
    }
}

extension AgentAttention {
    /// The state badge's SF Symbol (monochrome, tinted by `tone`).
    public var symbol: String { tone.symbol }
}

extension UsageLevel {
    /// The state palette (Task 18): under 70 % working teal, 70–90 % amber, from 90 % coral.
    public var tone: StateTone {
        switch self {
        case .normal: .working
        case .high: .needsYou
        case .critical: .error
        }
    }
}

/// One provider's usage chip in the Agents header: its most-used window.
public struct UsageReading: Equatable, Sendable {
    public let brand: AgentBrand
    /// "Claude", "Codex".
    public let provider: String
    /// "5 h" or "week".
    public let window: String
    public let usedPercent: Double
    public let resetsAt: Date?
    /// Every window this provider reports ("5 h 62%, week 30%"), for the tooltip and VoiceOver.
    public let detail: String

    public init(brand: AgentBrand, provider: String, window: String, usedPercent: Double, resetsAt: Date?,
                detail: String) {
        self.brand = brand
        self.provider = provider
        self.window = window
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.detail = detail
    }

    public var level: UsageLevel { UsageLevel(usedPercent: usedPercent) }

    /// Claude, then Codex: each provider's more-used window (5 h on a tie), so a nearly
    /// spent week is never hidden behind a quiet 5 hours.
    public static func chips(_ usage: Usage) -> [UsageReading] {
        var out: [UsageReading] = []
        let providers: [(String, String, Limits?)] = [("claude-code", "Claude", usage.claude),
                                                       ("codex", "Codex", usage.codex)]
        for (agent, name, limits) in providers {
            guard let limits else { continue }
            var windows: [(String, Window)] = []
            if let w = limits.fiveHour { windows.append(("5 h", w)) }
            if let w = limits.weekly { windows.append(("week", w)) }
            guard var best = windows.first else { continue }
            for w in windows.dropFirst() where w.1.usedPercent > best.1.usedPercent { best = w }
            let detail: String = windows.map { "\($0.0) \(PanelFormat.usagePercent($0.1.usedPercent))" }
                .joined(separator: ", ")
            out.append(UsageReading(brand: AgentBrand(agent: agent, agentName: name), provider: name,
                                    window: best.0, usedPercent: best.1.usedPercent, resetsAt: best.1.resetsAt,
                                    detail: detail))
        }
        return out
    }
}
