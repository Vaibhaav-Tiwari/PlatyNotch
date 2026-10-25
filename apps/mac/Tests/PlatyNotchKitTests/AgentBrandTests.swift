import Foundation
import XCTest
@testable import PlatyNotchKit

/// User change (Phase 4): agent icons and usage chips.
final class AgentBrandTests: DefaultsTestCase {
    func testBundleIDAllowlistAndMonograms() {
        let cases: [(String, String, String, [String])] = [
            ("claude-code", "Claude Code", "Cl", ["com.anthropic.claudefordesktop"]),
            ("codex", "Codex", "Cx", ["com.openai.codex", "com.openai.chat"]),
            ("cursor", "Cursor", "Cu", ["com.todesktop.230313mzl4w4u92"]),
            ("gemini", "Gemini CLI", "Ge", []),
            ("opencode", "OpenCode", "OC", []),
            ("qwen-code", "Qwen Code", "Qw", []),
            ("aider", "Aider", "Ai", []),
            ("x", "", "X", []),
            ("--", "", "Ag", []),
        ]
        for (agent, name, monogram, ids) in cases {
            let b = AgentBrand(agent: agent, agentName: name)
            XCTAssertEqual(b.monogram, monogram, agent)
            XCTAssertEqual(b.appBundleIDs, ids, agent)
        }
        XCTAssertEqual(AgentBrand(agent: "claude").key, AgentBrand(agent: "claude-code").key)
        XCTAssertEqual(AgentBrand(agent: "opencode").identity, .other)
    }

    /// The monogram's ink reaches 4.5:1 on every agent colour in both schemes.
    func testMonogramContrast() {
        let agents = ["claude-code", "codex", "cursor", "gemini", "opencode", "qwen", "aider"]
        for agent in agents {
            for dark in [true, false] {
                let b = AgentBrand(agent: agent)
                let ratio = RGB.contrast(b.background(dark: dark), b.ink(dark: dark).rgb)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(agent) dark=\(dark)")
            }
        }
        XCTAssertEqual(MonogramInk.on(RGB(hex: 0x000000)), .white)
        XCTAssertEqual(MonogramInk.on(RGB(hex: 0xFFFFFF)), .black)
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

    private func usage(_ json: String) -> Usage {
        (try? JSONCoding.decoder.decode(Usage.self, from: Data(json.utf8))) ?? Usage()
    }

    func testUsageChipsOnePerProviderMostUsedWindow() {
        let u = usage(#"{"claude":{"five_hour":{"used_percent":20},"weekly":{"used_percent":93},"updated_at":"2026-10-25T09:00:00Z"},"codex":{"five_hour":{"used_percent":40},"updated_at":"2026-10-25T09:00:00Z"}}"#)
        let chips = UsageReading.chips(u)
        XCTAssertEqual(chips.map(\.provider), ["Claude", "Codex"])
        XCTAssertEqual(chips[0].window, "week")
        XCTAssertEqual(chips[0].level, .critical)
        XCTAssertEqual(chips[0].detail, "5 h 20%, week 93%")
        XCTAssertEqual(chips[1].window, "5 h")
        XCTAssertEqual(chips[1].brand.key, "codex")
        let tie = usage(#"{"claude":{"five_hour":{"used_percent":50},"weekly":{"used_percent":50},"updated_at":"2026-10-25T09:00:00Z"}}"#)
        XCTAssertEqual(UsageReading.chips(tie).first?.window, "5 h")
        XCTAssertEqual(UsageReading.chips(Usage()), [])
    }
}
