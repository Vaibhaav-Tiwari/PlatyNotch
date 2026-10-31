import Foundation

/// How an agent is recognised at a glance: its own installed Mac app's icon when one of
/// `appBundleIDs` is installed (read at run time from the user's Mac, never bundled), else
/// its name as plain text (`displayName`). Never initials or a monogram (Quiet Notch spec 5.3).
public struct AgentBrand: Hashable, Sendable {
    /// One key per known agent ("claude", "codex", …), else the lowercased agent id.
    public let key: String
    public let identity: AgentIdentity
    /// The short name shown when no app icon is installed: "Claude", "Codex", "Aider".
    public let displayName: String
    /// The fixed allowlist of app bundle ids whose icon may stand for this agent, in order.
    public let appBundleIDs: [String]

    public init(agent: String, agentName: String = "") {
        let id = agent.lowercased()
        identity = AgentIdentity(agent: agent)
        switch id {
        case "claude-code", "claude":
            key = "claude"; displayName = "Claude"; appBundleIDs = ["com.anthropic.claudefordesktop"]
        case "codex":
            key = "codex"; displayName = "Codex"; appBundleIDs = ["com.openai.codex"]   // never ChatGPT's icon
        case "cursor", "cursor-agent":
            key = "cursor"; displayName = "Cursor"; appBundleIDs = ["com.todesktop.230313mzl4w4u92"]
        case "gemini", "gemini-cli":
            key = "gemini"; displayName = "Gemini"; appBundleIDs = []
        case "opencode":
            key = "opencode"; displayName = "OpenCode"; appBundleIDs = []
        case "qwen", "qwen-code":
            key = "qwen"; displayName = "Qwen"; appBundleIDs = []
        default:
            key = id
            let name: String = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            displayName = name.isEmpty ? agent : name
            appBundleIDs = []
        }
    }
}

extension AgentAttention {
    /// The state badge's SF Symbol (monochrome, tinted by `tone`).
    public var symbol: String { tone.symbol }
}

extension UsageLevel {
    /// The state palette: under 70 % working green, 70–90 % amber, from 90 % red.
    public var tone: StateTone {
        switch self {
        case .normal: .working
        case .high: .needsYou
        case .critical: .error
        }
    }
}
