import Foundation

/// Which agent a session or approval comes from, for its identity colour.
public enum AgentIdentity: String, CaseIterable, Sendable {
    case claude, codex, cursor, gemini, other

    /// From `Session.agent` / `Approval.agent`.
    public init(agent: String) {
        switch agent.lowercased() {
        case "claude-code", "claude": self = .claude
        case "codex": self = .codex
        case "cursor", "cursor-agent": self = .cursor
        case "gemini", "gemini-cli": self = .gemini
        default: self = .other
        }
    }

    /// The agent's colour on the black panel (the pill's per-agent dots). `other` is working.
    public var rgb: RGB {
        switch self {
        case .claude: RGB(hex: 0xE8833A)
        case .codex: RGB(hex: 0x3DBE7A)
        case .cursor: RGB(hex: 0x5B9BF8)
        case .gemini: RGB(hex: 0xA987F5)
        case .other: StateTone.working.rgb
        }
    }
}
