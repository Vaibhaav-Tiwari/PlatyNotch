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
        XCTAssertEqual(AgentDotStyle(.errored), .solid)
        XCTAssertEqual(AgentDotStyle(.idle), .hollow)
        XCTAssertEqual(AgentDotStyle(.finished), .hollow)
        let c = content([], sessions: [session("a", .active, agent: "codex"), session("b", .waitingInput, agent: "cursor"),
                                       session("c", .idle, agent: "gemini-cli")])
        XCTAssertEqual(c.dots.dots.map(\.key), ["b", "a", "c"])
        XCTAssertEqual(c.dots.dots.map(\.style), [.solid, .pulse, .hollow])
        XCTAssertEqual(c.dots.dots.map(\.agent), [.cursor, .codex, .gemini])
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
        // The "3 dots + +9" fit: at the Standard and Wide ears beside a notch, Platy, all
        // three dots and "+9" show (the "+9" as a badge on Platy where the label has no room).
        let pad = PanelLayout.pillPadding(hasNotch: true)
        for w in [AppearanceSettings.PillWidth.standard, .wide] {
            let ear = PanelLayout.ear(w) - pad
            let fit = PlatyEarFit(earWidth: ear, dots: 3, overflow: 9, outerPadding: pad)
            XCTAssertEqual(fit.dots, 3, "\(w)")
            XCTAssertEqual(fit.overflowCount, 9, "\(w)")
            XCTAssertLessThanOrEqual(fit.width, ear, "\(w)")
        }
    }

    /// With the pill's outer padding, a fit keeps the dots and badges Platy when the label
    /// has no room, and the badge never crosses a dot, the notch or the pill's edge.
    func testEarFitKeepsDotsWithBadge() throws {
        for w in AppearanceSettings.PillWidth.allCases {
            let pad = PanelLayout.pillPadding(hasNotch: true)
            let ear = PanelLayout.ear(w) - pad
            for dots in 0...3 {
                for overflow in [0, 1, 9, 40, 150] {
                    let fit = PlatyEarFit(earWidth: ear, dots: dots, overflow: overflow, outerPadding: pad)
                    let label = "\(w) dots=\(dots) overflow=\(overflow)"
                    XCTAssertEqual(fit.dots + fit.overflowCount, dots + overflow, label)
                    XCTAssertLessThanOrEqual(fit.width, max(ear, PlatyEarFit.platy), label)
                    guard fit.badge, fit.overflowCount > 0 else { continue }
                    let dotsWidth = CGFloat(fit.dots) * PlatyEarFit.dot
                    let width = try measuredBadge(PlatyEarFit.badgeText(fit.overflowCount))
                    let start = PlatyEarFit.badgeOffset(earWidth: ear, outerPadding: pad, badgeWidth: width,
                                                        dotsWidth: dotsWidth)
                    XCTAssertGreaterThanOrEqual(start, dotsWidth, "never over a dot: " + label)
                    XCTAssertLessThanOrEqual(start + width, ear + pad, "never past the pill's edge: " + label)
                }
            }
        }
        // The plain init keeps its old answer (no padding known: the label squeezes dots).
        XCTAssertEqual(PlatyEarFit(earWidth: 56, dots: 3, overflow: 4), PlatyEarFit(dots: 1, overflowCount: 6, badge: false))
    }

    func testBadgeEstimateNeverUnderMeasures() throws {
        for count in 1...150 {
            let text = PlatyEarFit.badgeText(count)
            XCTAssertGreaterThanOrEqual(PlatyEarFit.badgeWidthEstimate(count), try measuredBadge(text), text)
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

    /// The pill's badge width: 11 pt bold rounded, rounded up, plus `badgePadding` each side.
    private func measuredBadge(_ text: String) throws -> CGFloat {
        let base = NSFont.systemFont(ofSize: 11, weight: .bold)
        let descriptor = try XCTUnwrap(base.fontDescriptor.withDesign(.rounded))
        let font = try XCTUnwrap(NSFont(descriptor: descriptor, size: 11))
        return NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up)
            + 2 * PlatyEarFit.badgePadding
    }
}
