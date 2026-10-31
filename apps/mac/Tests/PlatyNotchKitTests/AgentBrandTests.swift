import Foundation
import XCTest
@testable import PlatyNotchKit

/// User change (Phase 4): agent icons and usage chips.
final class AgentBrandTests: DefaultsTestCase {
    func testBundleIDAllowlistAndNames() {
        let cases: [(String, String, String, [String])] = [
            ("claude-code", "Claude Code", "Claude", ["com.anthropic.claudefordesktop"]),
            ("codex", "Codex", "Codex", ["com.openai.codex"]),
            ("cursor", "Cursor", "Cursor", ["com.todesktop.230313mzl4w4u92"]),
            ("gemini", "Gemini CLI", "Gemini", []),
            ("opencode", "OpenCode", "OpenCode", []),
            ("qwen-code", "Qwen Code", "Qwen", []),
            ("aider", "Aider", "Aider", []),
            ("x", "", "x", []),
        ]
        for (agent, name, display, ids) in cases {
            let b = AgentBrand(agent: agent, agentName: name)
            XCTAssertEqual(b.displayName, display, agent)
            XCTAssertEqual(b.appBundleIDs, ids, agent)
        }
        XCTAssertEqual(AgentBrand(agent: "claude").key, AgentBrand(agent: "claude-code").key)
        XCTAssertEqual(AgentBrand(agent: "opencode").identity, .other)
    }

    /// Never initials: an agent without an installed app shows its name as text.
    func testNoMonogram() {
        XCTAssertEqual(AgentBrand(agent: "aider", agentName: "Aider").displayName, "Aider")
        XCTAssertEqual(AgentBrand(agent: "", agentName: "").displayName, "Agent", "never blank")
        XCTAssertEqual(AgentBrand(agent: "claude-code", agentName: "Claude Code").displayName, "Claude")
    }

    func testStateSymbolsAndTones() {
        let expected: [(AgentAttention, String, StateTone)] = [
            (.working, "bolt.fill", .working),
            (.needsYou, "hand.raised.fill", .needsYou),
            (.errored, "exclamationmark.triangle.fill", .error),
            (.finished, "checkmark", .done),
            (.idle, "moon.fill", .idle),
        ]
        for (a, symbol, tone) in expected {
            XCTAssertEqual(a.symbol, symbol, "\(a)")
            XCTAssertEqual(a.tone, tone, "\(a)")
        }
    }

    func testUsageThresholds() {
        XCTAssertEqual(UsageLevel(usedPercent: 0).tone, .working)
        XCTAssertEqual(UsageLevel(usedPercent: 69.9).tone, .working)
        XCTAssertEqual(UsageLevel(usedPercent: 70).tone, .needsYou)
        XCTAssertEqual(UsageLevel(usedPercent: 89.9).tone, .needsYou)
        XCTAssertEqual(UsageLevel(usedPercent: 90).tone, .error)
        XCTAssertEqual(UsageLevel(usedPercent: 120).tone, .error)
    }
}
