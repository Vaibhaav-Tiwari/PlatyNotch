import Foundation

/// Agents' header usage (Island spec 8): `rings`, one per agent with a five-hour window.
public enum UsageLine {}

/// One usage ring in Agents' header (Island spec 8): an agent's five-hour window.
public struct UsageRing: Equatable, Sendable {
    public let name: String
    /// 0...1 of the window used.
    public let fraction: Double
    /// Green, amber from 80 %, red from 95 %.
    public let tone: StateTone
    /// "Claude 62%".
    public let text: String

    public init(name: String, fraction: Double, tone: StateTone, text: String) {
        self.name = name
        self.fraction = fraction
        self.tone = tone
        self.text = text
    }
}

extension UsageLine {
    /// One ring per agent with a five-hour window; an agent without one is left out.
    public static func rings(_ u: Usage) -> [UsageRing] {
        let agents: [(String, Limits?)] = [("Claude", u.claude), ("Codex", u.codex)]
        return agents.compactMap { name, limits in
            guard let w = limits?.fiveHour else { return nil }
            let used: Double = w.usedPercent.isFinite ? w.usedPercent : 0
            let tone: StateTone = used < 80 ? .working : used < 95 ? .needsYou : .error
            return UsageRing(name: name, fraction: PanelFormat.usageFraction(used), tone: tone,
                             text: "\(name) \(PanelFormat.usagePercent(used))")
        }
    }
}

/// The one quiet line under the Agents list (spec 2.3): `2 open loops · Search memory with ⌘K`;
/// nil (hidden) at zero loops.
public enum AgentsFooter {
    public static let searchHint = "Search memory with \u{2318}K"

    public static func text(openLoops: Int) -> String? {
        guard openLoops > 0 else { return nil }
        return "\(loops(openLoops)) · \(searchHint)"
    }

    /// "1 open loop", "2 open loops".
    public static func loops(_ n: Int) -> String {
        n == 1 ? "1 open loop" : "\(n) open loops"
    }
}
