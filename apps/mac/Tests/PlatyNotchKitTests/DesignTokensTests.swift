import CoreGraphics
import Foundation
import XCTest
@testable import PlatyNotchKit

final class DesignTokensTests: DefaultsTestCase {

    /// Every token value in one table (spec 7, plan Task 1), compared in one loop.
    func testTokenGoldenTable() {
        func ts(_ size: CGFloat, _ w: TypeStyle.Weight, rounded: Bool = false, mono: Bool = false) -> TypeStyle {
            TypeStyle(size: size, weight: w, rounded: rounded, mono: mono)
        }
        let rows: [(String, AnyHashable, AnyHashable)] = [
            ("type.display", TypeScale.display.desc, ts(34, .semibold, rounded: true).desc),
            ("type.title", TypeScale.title.desc, ts(20, .semibold).desc),
            ("type.headline", TypeScale.headline.desc, ts(15, .semibold).desc),
            ("type.body", TypeScale.body.desc, ts(13, .regular).desc),
            ("type.caption", TypeScale.caption.desc, ts(11, .medium).desc),
            ("type.mono", TypeScale.mono.desc, ts(12, .regular, mono: true).desc),
            ("type.all", TypeScale.all.map(\.desc), [TypeScale.display, TypeScale.title, TypeScale.headline,
                                                  TypeScale.body, TypeScale.caption, TypeScale.mono].map(\.desc)),
            ("type.minimum", TypeScale.minimum, CGFloat(11)),
            ("space.scale", Space.scale, [CGFloat(4), 8, 12, 16, 24, 32]),
            ("space.steps", [Space.xs, Space.s, Space.m, Space.l, Space.xl, Space.xxl], Space.scale),
            ("space.panelMargin", Space.panelMargin, CGFloat(16)),
            ("space.heroPadding", Space.heroPadding, CGFloat(20)),
            ("radius.scale", Radius.scale, [CGFloat(6), 12, 20]),
            ("radius.steps", [Radius.chip, Radius.card, Radius.hero], Radius.scale),
            ("icon", [IconSize.row, IconSize.tile, IconSize.hero], [CGFloat(15), 20, 28]),
            ("elevation", Elevation.allCases.map { "\($0)" }, ["surface", "card"]),
            ("brand.teal", Brand.teal.hexString, "2FB8A6"),
            ("brand.cream", Brand.cream.hexString, "F2E6C9"),
            ("brand.pond", Brand.pond.hexString, "1C3B4A"),
            ("panelDark", PanelPalette.panelDark.hexString, "0B0D0D"),
            ("keylineAlpha", PanelPalette.keylineAlpha, 0.08),
        ]
        let states: [(StateTone, String, String, String, String)] = [
            (.working, "2FB8A6", "0B6B5F", "arrow.triangle.2.circlepath", "Working"),
            (.needsYou, "F5A524", "845000", "hand.raised.fill", "Needs you"),
            (.error, "F2685B", "A3352B", "exclamationmark.triangle.fill", "Error"),
            (.done, "4CC38A", "17693F", "checkmark.circle.fill", "Done"),
            (.idle, "9AA0A6", "585D62", "moon.zzz.fill", "Idle"),
        ]
        let agents: [(AgentIdentity, String, String)] = [
            (.claude, "E8833A", "904410"),
            (.codex, "3DBE7A", "17693F"),
            (.cursor, "5B9BF8", "1F5BB8"),
            (.gemini, "A987F5", "6A3FC4"),
            (.other, "2FB8A6", "0B6B5F"),
        ]
        var all = rows
        XCTAssertEqual(states.map(\.0), StateTone.allCases)
        XCTAssertEqual(agents.map(\.0), AgentIdentity.allCases)
        for (tone, dark, light, symbol, word) in states {
            all.append(("state.\(tone).dark", tone.rgb(dark: true).hexString, dark))
            all.append(("state.\(tone).light", tone.rgb(dark: false).hexString, light))
            all.append(("state.\(tone).symbol", tone.symbol, symbol))
            all.append(("state.\(tone).word", tone.word, word))
        }
        for (agent, dark, light) in agents {
            all.append(("agent.\(agent).dark", agent.rgb(dark: true).hexString, dark))
            all.append(("agent.\(agent).light", agent.rgb(dark: false).hexString, light))
        }
        for (name, actual, expected) in all {
            XCTAssertEqual(actual, expected, name)
        }
    }

    func testRadiusInner() {
        XCTAssertEqual(Radius.inner(outer: 20, padding: 20), 0)
        XCTAssertEqual(Radius.inner(outer: 20, padding: 8), 12)
        XCTAssertEqual(Radius.inner(outer: 6, padding: 8), 0)
    }

    func testColoursMeetContrast() {
        let white = RGB(hex: 0xFFFFFF), black = RGB(hex: 0x000000)
        let alpha = PanelPalette.cardOverlay
        let darkBacks: [(String, RGB)] = [
            ("panelDark", PanelPalette.panelDark),
            ("panelDark card", PanelPalette.panelDark.under(white, alpha: alpha)),
            ("darkSurface", PanelPalette.darkSurface),
        ]
        let lightBacks: [(String, RGB)] = [
            ("lightSurface", PanelPalette.lightSurface),
            ("lightSurface card", PanelPalette.lightSurface.under(black, alpha: alpha)),
        ]
        var fg: [(String, RGB, RGB)] = StateTone.allCases.map { ("\($0)", $0.rgb(dark: true), $0.rgb(dark: false)) }
        fg += AgentIdentity.allCases.map { ("agent \($0)", $0.rgb(dark: true), $0.rgb(dark: false)) }
        for (name, dark, light) in fg {
            for (bName, back) in darkBacks {
                XCTAssertGreaterThanOrEqual(RGB.contrast(dark, back), 4.5, "\(name) dark on \(bName)")
            }
            for (bName, back) in lightBacks {
                XCTAssertGreaterThanOrEqual(RGB.contrast(light, back), 4.5, "\(name) light on \(bName)")
            }
        }
        // Black text on an amber fill (the pill's approval-count badge and the ringing chip's
        // Stop) uses the dark amber in every scheme: the light amber is about 3.1:1.
        let amberFill = StateTone.needsYou.rgb(dark: true)
        for use in ["approval badge count", "ringing chip Stop"] {
            XCTAssertGreaterThanOrEqual(RGB.contrast(black, amberFill), 4.5, "\(use): black on the amber fill")
        }
        XCTAssertLessThan(RGB.contrast(black, StateTone.needsYou.rgb(dark: false)), 4.5, "why the fill is the dark amber")
        XCTAssertGreaterThanOrEqual(RGB.contrast(Brand.teal, PanelPalette.panelDark), 4.5)
        XCTAssertGreaterThanOrEqual(RGB.contrast(Brand.cream, Brand.pond), 4.5)
        XCTAssertGreaterThanOrEqual(RGB.contrast(white, Brand.pond), 4.5)
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
        XCTAssertEqual(AgentIdentity.other.rgb(dark: true), StateTone.working.rgb(dark: true))
    }
}

private extension TypeStyle {
    var desc: String { "\(size) \(weight) rounded=\(rounded) mono=\(mono)" }
}

private extension RGB {
    var hexString: String {
        func c(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return c(r) + c(g) + c(b)
    }
}
