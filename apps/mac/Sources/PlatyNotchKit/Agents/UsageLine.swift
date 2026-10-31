import Foundation

/// Agents' header status text (Quiet Notch spec 2.1): usage as small mono numbers, one part
/// per agent, `Claude 5h 62% · 7d 31%` and `Codex 5h 18%`. Percents are rounded; a missing
/// window or an agent without any is left out. No rings or tiles.
public enum UsageLine {
    public static func parts(_ u: Usage) -> [String] {
        let agents: [(String, Limits?)] = [("Claude", u.claude), ("Codex", u.codex)]
        var out: [String] = []
        for (name, limits) in agents {
            guard let limits else { continue }
            var windows: [String] = []
            if let w = limits.fiveHour { windows.append("5h \(PanelFormat.usagePercent(w.usedPercent))") }
            if let w = limits.weekly { windows.append("7d \(PanelFormat.usagePercent(w.usedPercent))") }
            guard !windows.isEmpty else { continue }
            out.append("\(name) " + windows.joined(separator: " · "))
        }
        return out
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
