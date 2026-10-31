import CoreGraphics
import Foundation
import XCTest
@testable import PlatyNotchKit

final class DesignTokensTests: DefaultsTestCase {

    /// Every token value in one table (Quiet Notch spec 5.1, plan Task 14), compared in one loop.
    func testTokenGoldenTable() {
        func ts(_ size: CGFloat, _ w: TypeStyle.Weight, mono: Bool = false) -> TypeStyle {
            TypeStyle(size: size, weight: w, mono: mono)
        }
        let rows: [(String, AnyHashable, AnyHashable)] = [
            ("type.title", TypeScale.title.desc, ts(14, .semibold).desc),
            ("type.display", TypeScale.display.map(\.desc),
             [TypeStyle(size: 34, weight: .semibold, rounded: true).desc, TypeStyle(size: 54, weight: .semibold, rounded: true).desc]),
            ("type.small", [TypeScale.dockLabel.desc, TypeScale.badge.desc, TypeScale.pillTime.desc],
             [ts(10.5, .regular).desc, ts(10, .semibold).desc, TypeStyle(size: 12, weight: .semibold, rounded: true).desc]),
            ("type.body", TypeScale.body.desc, ts(13, .regular).desc),
            ("type.secondary", TypeScale.secondary.desc, ts(12, .regular).desc),
            ("type.caption", TypeScale.caption.desc, ts(11, .regular).desc),
            ("type.mono", TypeScale.mono.desc, ts(12, .regular, mono: true).desc),
            ("type.glyph", TypeScale.glyph.desc, ts(15, .semibold).desc),
            ("type.all", TypeScale.all.map(\.desc), [TypeScale.title, TypeScale.body, TypeScale.secondary,
                                                  TypeScale.caption, TypeScale.mono, TypeScale.glyph,
                                                  TypeScale.dockLabel, TypeScale.badge, TypeScale.pillTime].map(\.desc)),
            ("type.maximum", TypeScale.maximum, CGFloat(15)),
            ("type.minimum", TypeScale.minimum, CGFloat(10)),
            ("type.literalMinimum", TypeScale.literalMinimum, CGFloat(11)),
            ("space.scale", Space.scale, [CGFloat(4), 8, 12, 16, 24, 32]),
            ("space.panel", [Space.panelTop, Space.panelSide, Space.panelBottom], [CGFloat(30), 16, 14]),
            ("space.header", Space.header, CGFloat(14)),
            ("space.columnGap", Space.columnGap, CGFloat(22)),
            ("radius", [Radius.keycap, Radius.small, Radius.medium, Radius.card, Radius.island, Radius.panelBottom],
             [CGFloat(4), 6, 8, 12, 16, 22]),
            ("radius.scale", Radius.scale, [CGFloat(4), 6, 8, 12, 16, 22]),
            ("surface", [Surface.card, Surface.raised, Surface.stroke, Surface.countBlue].map(\.hexString),
             ["121214", "1C1C1F", "2A2A2E", "4C8DFF"]),
            ("home", [HomeMetrics.panelWidth, HomeMetrics.artSize, HomeMetrics.dockCircle, HomeMetrics.dockSlot,
                      HomeMetrics.agentIcon], [CGFloat(640), 74, 38, 66, 24]),
            ("home.cards", [HomeMetrics.cardGap, HomeMetrics.dockTop, HomeMetrics.cardPadding, HomeMetrics.toolPadding,
                            HomeMetrics.sourceBadge, HomeMetrics.sourceBadgeBorder, HomeMetrics.glowBlur,
                            HomeMetrics.progressHeight, HomeMetrics.weatherSymbol, HomeMetrics.weekDay, HomeMetrics.weekMark,
                            HomeMetrics.nowPlayingRatio], [CGFloat(10), 12, 12, 14, 20, 2, 34, 4, 40, 22, 20, 1.25]),
            ("home.glow", [HomeMetrics.glowOpacity, HomeMetrics.liveFill], [0.45, 0.18]),
            ("icon", [IconSize.symbol, IconSize.header], [CGFloat(14), 16]),
            ("brand.cream", Brand.cream.hexString, "F2E6C9"),
            ("panel", PanelPalette.panel.hexString, "000000"),
            ("approvalCard", PanelPalette.approvalCard.hexString, "111111"),
            ("ink", [Ink.primary, Ink.secondary, Ink.tertiary, Ink.hairline, Ink.rowHairline], [0.94, 0.60, 0.36, 0.06, 0.05]),
            ("ink.fill", Ink.fill, 0.07),
        ]
        let states: [(StateTone, String, Double, String, String)] = [
            (.working, "32D74B", 1, "bolt.fill", "Working"),
            (.needsYou, "FFB340", 1, "hand.raised.fill", "Needs you"),
            (.error, "FF6961", 1, "exclamationmark.triangle.fill", "Error"),
            (.done, "FFFFFF", Ink.secondary, "checkmark", "Done"),
            (.idle, "FFFFFF", Ink.tertiary, "moon.fill", "Idle"),
        ]
        var all = rows
        XCTAssertEqual(states.map(\.0), StateTone.allCases)
        for (tone, hex, alpha, symbol, word) in states {
            all.append(("state.\(tone).rgb", tone.rgb.hexString, hex))
            all.append(("state.\(tone).alpha", tone.alpha, alpha))
            all.append(("state.\(tone).symbol", tone.symbol, symbol))
            all.append(("state.\(tone).word", tone.word, word))
        }
        for (name, actual, expected) in all {
            XCTAssertEqual(actual, expected, name)
        }
    }

    /// Text styles stay in 10…15; the two display numbers (temperature, timer) are separate.
    func testTypeNeverAboveFifteen() {
        XCTAssertTrue(TypeScale.all.allSatisfy { $0.size <= 15 && $0.size >= 10 })
        XCTAssertEqual(TypeScale.display.map(\.size), [34, 54])
        XCTAssertFalse(TypeScale.display.contains { d in TypeScale.all.contains { $0 == d } })
        XCTAssertEqual(TypeScale.all.map(\.size).max(), TypeScale.maximum)
        XCTAssertEqual(TypeScale.all.map(\.size).min(), TypeScale.minimum)
    }

    func testRadiusInner() {
        XCTAssertEqual(Radius.inner(outer: 20, padding: 20), 0)
        XCTAssertEqual(Radius.inner(outer: 20, padding: 8), 12)
        XCTAssertEqual(Radius.inner(outer: 6, padding: 8), 0)
    }

    /// State colours read on the black panel and on the approval card.
    func testColoursMeetContrast() {
        let black = RGB(hex: 0x000000)
        for back in [PanelPalette.panel, PanelPalette.approvalCard] {
            for tone in [StateTone.working, .needsYou, .error] {
                XCTAssertGreaterThanOrEqual(RGB.contrast(tone.rgb, back), 4.5, "\(tone)")
            }
            for agent in AgentIdentity.allCases {
                XCTAssertGreaterThanOrEqual(RGB.contrast(agent.rgb, back), 4.5, "agent \(agent)")
            }
        }
        // Black text on the amber fill (the pill's approval-count badge and the ringing chip's Stop).
        XCTAssertGreaterThanOrEqual(RGB.contrast(black, StateTone.needsYou.rgb), 4.5)
        // Allow: green text on green at 0.12 over the card.
        let allowFill = PanelPalette.approvalCard.under(StateTone.working.rgb, alpha: 0.12)
        XCTAssertGreaterThanOrEqual(RGB.contrast(StateTone.working.rgb, allowFill), 4.5)
    }

    func testNoTeal() {
        let teal = "2FB8A6"
        XCTAssertFalse(StateTone.allCases.contains { $0.rgb.hexString == teal })
        XCTAssertFalse(AgentIdentity.allCases.contains { $0.rgb.hexString == teal })
        XCTAssertEqual(AgentIdentity.other.rgb, StateTone.working.rgb)
    }

    func testAgentIdentityMapping() {
        XCTAssertEqual(AgentIdentity(agent: "claude-code"), .claude)
        XCTAssertEqual(AgentIdentity(agent: "claude"), .claude)
        XCTAssertEqual(AgentIdentity(agent: "codex"), .codex)
        XCTAssertEqual(AgentIdentity(agent: "cursor-agent"), .cursor)
        XCTAssertEqual(AgentIdentity(agent: "cursor"), .cursor)
        XCTAssertEqual(AgentIdentity(agent: "gemini-cli"), .gemini)
        XCTAssertEqual(AgentIdentity(agent: "gemini"), .gemini)
        XCTAssertEqual(AgentIdentity(agent: "aider"), .other)
    }
}

private extension TypeStyle {
    var desc: String { "\(size) \(weight) mono=\(mono) rounded=\(rounded)" }
}

extension RGB {
    var hexString: String {
        func c(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return c(r) + c(g) + c(b)
    }
}
