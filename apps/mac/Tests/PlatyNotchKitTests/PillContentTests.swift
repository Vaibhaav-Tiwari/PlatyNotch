import AppKit
import Foundation
import PlatyNotchKit
import XCTest

final class PillContentTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func act(_ id: String, _ priority: Int, expires: Date? = nil, started: TimeInterval? = nil) -> LiveActivity {
        LiveActivity(id: id, widgetID: id, priority: priority, glyph: .symbol("circle"), trailing: id,
                     expiresAt: expires, startedAt: started.map { now.addingTimeInterval($0) })
    }

    private func session(_ key: String, _ state: SessionState, agent: String = "claude-code") -> Session {
        Session(key: key, agent: agent, agentName: agent, sessionID: key, state: state, startedAt: now, updatedAt: now)
    }

    private func content(_ activities: [LiveActivity], sessions: [Session] = [], approvals: Int = 0,
                         hidden: Set<NotificationKind> = []) -> PillContent {
        PillContent(activities: activities, sessions: sessions, approvals: approvals, hiddenKinds: hidden, now: now)
    }

    func testTrailingIsTopNonAgent() {
        let c = content([act("music", LivePriority.musicPlaying), act("timer", LivePriority.timerRunning)],
                        sessions: [session("a", .active)])
        XCTAssertEqual(c.trailing?.id, "timer")
        XCTAssertEqual(c.indicators.map(\.id), ["music"])
        XCTAssertEqual(c.dots.dots.map(\.key), ["a"], "the agents go to the dots, never the trailing side")
    }

    func testAtMostTwoIndicators() {
        let c = content([act("music", LivePriority.musicPlaying), act("timer", LivePriority.timerRunning),
                         act("download", LivePriority.download), act("awake", LivePriority.keepAwake),
                         act("ring", LivePriority.alarmRinging)])
        XCTAssertEqual(PillContent.indicatorLimit, 2)
        XCTAssertEqual(c.trailing?.id, "ring")
        XCTAssertEqual(c.indicators.map(\.id), ["timer", "download"])
    }

    func testAmbientNeverBesideLive() {
        let c = content([act("shelf", LivePriority.shelfItems), act("music", LivePriority.musicPlaying),
                         act("charging", LivePriority.batteryCharging)])
        XCTAssertEqual(c.trailing?.id, "music")
        XCTAssertEqual(c.indicators, [], "ambient items never sit beside a live one")
        let alone = content([act("shelf", LivePriority.shelfItems), act("charging", LivePriority.batteryCharging)])
        XCTAssertEqual(alone.trailing?.id, "shelf", "ambient shows when nothing else is live")
        XCTAssertEqual(alone.indicators.map(\.id), ["charging"])
        XCTAssertNil(content([act("old", LivePriority.timerRunning, expires: now)]).trailing, "expired items are gone")
    }

    func testHiddenKindLeavesThePill() {
        let c = content([act("music", LivePriority.musicPlaying), act("ring", LivePriority.alarmRinging)],
                        hidden: [.other])
        XCTAssertEqual(c.trailing?.id, "ring")
        XCTAssertEqual(c.indicators, [], "music is 'everything else' and was hidden")
        let none = content([act("music", LivePriority.musicPlaying)], hidden: [.other])
        XCTAssertNil(none.trailing)
        XCTAssertFalse(none.keepsMinimalUp, "a hidden item does not keep Minimal up")
    }

    func testDotStyles() {
        XCTAssertEqual(AgentDotStyle(.working), .pulse)
        XCTAssertEqual(AgentDotStyle(.needsYou), .solid)
        XCTAssertEqual(AgentDotStyle(.errored), .errored)
        XCTAssertEqual(AgentDotStyle(.idle), .dim)
        XCTAssertEqual(AgentDotStyle(.finished), .dim)
        let c = content([], sessions: [session("a", .active, agent: "codex"), session("b", .waitingInput, agent: "cursor"),
                                       session("c", .idle, agent: "gemini-cli")])
        XCTAssertEqual(c.dots.dots.map(\.key), ["b", "a", "c"])
        XCTAssertEqual(c.dots.dots.map(\.style), [.solid, .pulse, .dim])
        XCTAssertEqual(c.dots.dots.map(\.agent), [.cursor, .codex, .gemini])
    }

    /// Hotfix: every dot is a solid circle. There is no hollow (ring) style; idle and
    /// finished rest at 35% opacity, waiting and errored at full opacity.
    func testNoHollowStyleAndIdleIsDimmed() {
        XCTAssertEqual(AgentDotStyle.allCases, [.pulse, .solid, .dim, .errored])
        for style in AgentDotStyle.allCases {
            XCTAssertFalse(String(describing: style).lowercased().contains("hollow"))
            XCTAssertFalse(String(describing: style).lowercased().contains("ring"))
        }
        XCTAssertEqual(AgentDotStyle(.idle).opacity, 0.35)
        XCTAssertEqual(AgentDotStyle(.finished).opacity, 0.35)
        XCTAssertEqual(AgentDotStyle(.needsYou).opacity, 1)
        XCTAssertEqual(AgentDotStyle(.errored).opacity, 1)
        XCTAssertEqual(AgentDotStyle(.working).opacity, 1, "a pulse animates down from full opacity")
    }

    /// With the finish log an errored session's dot is coral (`.errored`) and a finished
    /// one is dimmed; the order still comes from the state alone.
    func testDotsUseTheFinishLog() {
        var log = AgentFinishLog()
        log.noteFailure(sessionKey: "e", at: now)
        log.record(SessionChanges(finished: ["f"], enteredNeedsYou: [], allFinished: false), now: now)
        let c = PillContent(activities: [], sessions: [session("e", .idle), session("w", .active), session("f", .idle)],
                            approvals: 0, hiddenKinds: [], log: log, now: now)
        XCTAssertEqual(c.dots.dots.map(\.key), ["w", "e", "f"])
        XCTAssertEqual(c.dots.dots.map(\.style), [.pulse, .errored, .dim])
    }

    func testTwelveSessions() {
        let agents = ["claude-code", "codex", "cursor", "gemini"]
        var sessions = (0..<12).map { i in session("s\(i)", i % 3 == 0 ? .idle : .active, agent: agents[i % 4]) }
        sessions[7].state = .waitingInput
        let c = content([], sessions: sessions)
        XCTAssertEqual(c.dots.dots.count, 3)
        XCTAssertEqual(c.dots.dots.first?.key, "s7")
        XCTAssertEqual(c.dots.dots.first?.style, .solid)
        XCTAssertEqual(c.dots.dots.first?.agent, .gemini)
        XCTAssertEqual(c.dots.overflow, 9)
        // Wide beside a notch: Platy, all three dots and a plain "+9".
        let pad = PanelLayout.pillPadding(hasNotch: true)
        let wide = PanelLayout.ear(.wide) - pad
        let fit = PlatyEarFit(earWidth: wide, dots: 3, overflow: 9, labelWidth: measuredLabel)
        XCTAssertEqual(fit, PlatyEarFit(dots: 3, overflowCount: 9))
        // Standard: fewer dots, "+n" kept. Compact: "+n" dropped, one dot beside Platy.
        let standard = PanelLayout.ear(.standard) - pad
        XCTAssertEqual(PlatyEarFit(earWidth: standard, dots: 3, overflow: 9, labelWidth: measuredLabel),
                       PlatyEarFit(dots: 1, overflowCount: 11))
        let compact = PanelLayout.ear(.compact) - pad
        XCTAssertEqual(PlatyEarFit(earWidth: compact, dots: 3, overflow: 9, labelWidth: measuredLabel),
                       PlatyEarFit(dots: 1, overflowCount: 0))
    }

    /// The fit order with the measured "+n" for every count from 1 to 150, at all three
    /// ear widths beside a notch and without one: fewer dots (down to one) while "+n"
    /// stays; then "+n" goes and the dots that fit stay; then Platy alone. Nothing overlaps
    /// Platy, nothing passes the notch edge or the pill's edge, and text is never cut.
    func testFitOrderNeverOverlaps() {
        let pad = PanelLayout.pillPadding(hasNotch: true)
        var ears: [(String, CGFloat, CGFloat)] = AppearanceSettings.PillWidth.allCases.map { w in
            ("\(w) notch", PanelLayout.ear(w) - pad, pad)
        }
        for w in AppearanceSettings.PillWidth.allCases {
            let plain = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                                    auxLeft: nil, auxRight: nil, pillWidth: w)
            ears.append(("\(w) plain", plain.liveEarWidth, PanelLayout.pillPadding(hasNotch: false)))
        }
        for (name, ear, outer) in ears {
            let room = ear - PlatyEarFit.platy
            for total in 1...150 {
                let dots = min(total, PillDots.limit)
                let overflow = total - dots
                let fit = PlatyEarFit(earWidth: ear, dots: dots, overflow: overflow, labelWidth: measuredLabel)
                let label = "\(name) total=\(total) fit=\(fit)"
                let width = fit.overflowCount > 0 ? measuredLabel(fit.overflowCount) : 0
                let place = fit.placement(labelWidth: width)
                // Platy at the outer edge; nothing over it; nothing past the notch or pill edge.
                // The ear starts `outer` inside the pill's edge; Platy sits at the ear's start.
                XCTAssertEqual(place.platy.lowerBound, 0, label)
                XCTAssertGreaterThan(outer + place.platy.lowerBound, 0, "inside the pill's outer edge: " + label)
                var last: CGFloat = place.platy.upperBound
                for d in place.dots {
                    XCTAssertGreaterThan(d.lowerBound, last, "a dot overlaps Platy or a dot: " + label)
                    XCTAssertEqual(d.upperBound - d.lowerBound, PlatyEarFit.dotSize, label)
                    last = d.upperBound
                }
                if let l = place.label {
                    XCTAssertGreaterThan(l.lowerBound, last, "the label overlaps: " + label)
                    last = l.upperBound
                }
                XCTAssertLessThanOrEqual(last, ear, "passes the notch edge: " + label)
                XCTAssertEqual(fit.width(labelWidth: width), max(last, PlatyEarFit.platy), label)
                // The order.
                XCTAssertGreaterThanOrEqual(fit.dots, 1, "every ear holds Platy and a dot: " + label)
                if fit.overflowCount > 0 {
                    XCTAssertEqual(fit.dots + fit.overflowCount, total, "+n counts every other session: " + label)
                    if fit.dots < dots {
                        let more = CGFloat(fit.dots + 1) * PlatyEarFit.dot + PlatyEarFit.spacing
                            + measuredLabel(total - fit.dots - 1)
                        XCTAssertGreaterThan(more, room, "one more dot would have fit with +n: " + label)
                    }
                } else if fit.dots < total {
                    let withLabel = PlatyEarFit.dot + PlatyEarFit.spacing + measuredLabel(total - 1)
                    XCTAssertGreaterThan(withLabel, room, "+n dropped though one dot and +n fit: " + label)
                    XCTAssertEqual(fit.dots, min(dots, Int((room / PlatyEarFit.dot).rounded(.down))),
                                   "after +n goes, the dots that fit stay: " + label)
                }
            }
        }
    }

    func testLabelEstimateNeverUnderMeasures() {
        for count in 1...150 {
            XCTAssertGreaterThanOrEqual(PlatyEarFit.labelWidthEstimate(count), measuredLabel(count),
                                        PlatyEarFit.overflowText(count))
        }
    }

    func testEarFitDropsIndicatorsFirst() {
        let wide = LiveEarFit(earWidth: 90, hasTrailing: true, indicators: 2)
        XCTAssertEqual(wide.indicatorsShown, 2)
        XCTAssertGreaterThanOrEqual(wide.trailingWidth, LiveEarFit.minTrailing)
        // 58 (Standard): glyph 20, text needs 4 + 34; one indicator costs 10, so none fit.
        let standard = LiveEarFit(earWidth: 58, hasTrailing: true, indicators: 2)
        XCTAssertEqual(standard.indicatorsShown, 0, "indicators go before the text")
        XCTAssertGreaterThanOrEqual(standard.trailingWidth, LiveEarFit.minTrailing)
        let one = LiveEarFit(earWidth: 68, hasTrailing: true, indicators: 2)
        XCTAssertEqual(one.indicatorsShown, 1)
        XCTAssertGreaterThanOrEqual(one.trailingWidth, LiveEarFit.minTrailing)
        let noText = LiveEarFit(earWidth: 34, hasTrailing: true, indicators: 2)
        XCTAssertEqual(noText.trailingWidth, 0)
        XCTAssertEqual(noText.indicatorsShown, 1, "with the text hidden, what fits of the indicators shows")
        for w in stride(from: 0.0, through: 140.0, by: 1) {
            for n in 0...2 {
                for text in [true, false] {
                    let fit = LiveEarFit(earWidth: CGFloat(w), hasTrailing: text, indicators: n)
                    XCTAssertLessThanOrEqual(fit.usedWidth, max(CGFloat(w), LiveEarFit.glyph), "w=\(w)")
                    XCTAssertLessThanOrEqual(fit.indicatorsShown, n)
                    XCTAssertFalse(fit.showsBubble)
                    if fit.trailingWidth > 0 { XCTAssertGreaterThanOrEqual(fit.trailingWidth, LiveEarFit.minTrailing) }
                }
            }
        }
    }

    func testBubbleInitStillWorks() {
        let fit = LiveEarFit(earWidth: 90, hasTrailing: true, hasBubble: true)
        XCTAssertTrue(fit.showsBubble)
        XCTAssertEqual(fit.indicatorsShown, 0)
        XCTAssertEqual(fit.trailingWidth, 90 - LiveEarFit.glyph - LiveEarFit.spacing - LiveEarFit.bubble - LiveEarFit.spacing)
    }

    func testKeepsMinimalUp() {
        XCTAssertFalse(content([]).keepsMinimalUp)
        XCTAssertTrue(content([], approvals: 1).keepsMinimalUp)
        XCTAssertFalse(content([act("shelf", LivePriority.shelfItems)]).keepsMinimalUp, "ambient never keeps it up")
        XCTAssertTrue(content([act("music", LivePriority.musicPlaying)]).keepsMinimalUp)
        XCTAssertTrue(content([], sessions: [session("a", .active)]).keepsMinimalUp)
        XCTAssertTrue(content([], sessions: [session("a", .waitingInput)]).keepsMinimalUp)
        XCTAssertFalse(content([], sessions: [session("a", .idle)]).keepsMinimalUp)
    }

    // MARK: - Fix round 1

    /// Every live session is counted by state, overflow included; errored and finished
    /// come from the finish log.
    func testSessionsSummaryNamesStates() {
        let sessions = (0..<12).map { i in session("s\(i)", i == 3 ? .waitingInput : .active) }
        let c = content([], sessions: sessions)
        XCTAssertEqual(c.sessionsSummary, "12 agent sessions: 1 needs you, 11 working")
        var log = AgentFinishLog()
        log.record(SessionChanges(finished: ["f"], enteredNeedsYou: [], allFinished: false), now: now)
        log.noteFailure(sessionKey: "e", at: now)
        let mixed = PillContent(activities: [], sessions: [session("f", .idle), session("e", .idle), session("i", .idle),
                                                          session("x", .exited), session("w", .active)],
                                approvals: 0, hiddenKinds: [], log: log, now: now)
        XCTAssertEqual(mixed.sessionsSummary, "4 agent sessions: 1 errored, 1 working, 1 finished, 1 idle")
        XCTAssertEqual(content([]).sessionsSummary, "No agent sessions")
        XCTAssertEqual(content([], sessions: [session("a", .idle)]).sessionsSummary, "1 agent session: 1 idle")
    }

    /// Ruling 4 with agents counted as live: ambient items leave the pill while an agent
    /// works or waits, or an approval is pending.
    func testAmbientLeavesWhileAgentsAreLive() {
        let shelf = act("shelf", LivePriority.shelfItems)
        let charging = act("charging", LivePriority.batteryCharging)
        XCTAssertEqual(content([shelf, charging]).trailing?.id, "shelf")
        let working = content([shelf, charging], sessions: [session("a", .active)])
        XCTAssertNil(working.trailing)
        XCTAssertEqual(working.indicators, [])
        XCTAssertNil(content([shelf], sessions: [session("a", .waitingInput)]).trailing)
        XCTAssertNil(content([shelf], approvals: 1).trailing)
        XCTAssertEqual(content([shelf], sessions: [session("a", .idle)]).trailing?.id, "shelf", "idle agents are not live")
        let music = content([act("music", LivePriority.musicPlaying), shelf], sessions: [session("a", .active)])
        XCTAssertEqual(music.trailing?.id, "music")
    }

    /// The "+n" label as the pill draws it: 11 pt medium rounded, rounded up.
    private func measuredLabel(_ count: Int) -> CGFloat {
        let base = NSFont.systemFont(ofSize: 11, weight: .medium)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? base
        return NSAttributedString(string: PlatyEarFit.overflowText(count), attributes: [.font: font]).size().width
            .rounded(.up)
    }
}
