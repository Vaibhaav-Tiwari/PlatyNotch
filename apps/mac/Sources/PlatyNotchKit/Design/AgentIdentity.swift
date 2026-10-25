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

    /// The agent's colour; light values reach 4.5:1 on the light surface. `other` is working.
    public func rgb(dark: Bool) -> RGB {
        switch self {
        case .claude: RGB(hex: dark ? 0xE8833A : 0x904410)
        case .codex: RGB(hex: dark ? 0x3DBE7A : 0x17693F)
        case .cursor: RGB(hex: dark ? 0x5B9BF8 : 0x1F5BB8)
        case .gemini: RGB(hex: dark ? 0xA987F5 : 0x6A3FC4)
        case .other: StateTone.working.rgb(dark: dark)
        }
    }
}
