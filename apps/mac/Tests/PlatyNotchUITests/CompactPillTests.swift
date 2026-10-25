import AppKit
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class CompactPillTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func act(_ id: String, _ priority: Int, trailing: String? = nil, label: String? = nil) -> LiveActivity {
        LiveActivity(id: id, widgetID: id, priority: priority, glyph: .symbol("timer"), trailing: trailing,
                     accessibilityLabel: label)
    }

    private func content(_ activities: [LiveActivity], sessions: [Session] = [], approvals: Int = 0) -> PillContent {
        PillContent(activities: activities, sessions: sessions, approvals: approvals, hiddenKinds: [], now: now)
    }

    /// A 200-character trailing text, with two indicators, never draws past the live ear
    /// at any pill width.
    func testTrailingNeverWiderThanEar() {
        let long = String(repeating: "Long title ", count: 19) + "the end"
        XCTAssertGreaterThanOrEqual(long.count, 200)
        let c = content([act("timer", LivePriority.timerRunning, trailing: long),
                         act("music", LivePriority.musicPlaying), act("download", LivePriority.download)])
        XCTAssertEqual(c.indicators.count, 2)
        let pad = PanelLayout.pillPadding(hasNotch: true)
        for w in AppearanceSettings.PillWidth.allCases {
            let ear = PanelLayout.ear(w) - pad
            let host = NSHostingView(rootView: LiveEarView(content: c, connection: .connected, earWidth: ear)
                .environment(\.colorScheme, .dark))
            host.frame = CGRect(x: 0, y: 0, width: 400, height: 32)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, ear + 0.5, "\(w)")
            XCTAssertGreaterThan(host.fittingSize.width, 0, "\(w)")
        }
    }

    func testHollowDotNeverAnimates() {
        let view = AgentDotNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.configure(color: .systemTeal, style: .hollow)
        XCTAssertFalse(view.isPulsing)
        XCTAssertTrue(view.isHollow)
        view.configure(color: .systemTeal, style: .pulse)
        XCTAssertTrue(view.isPulsing)
        XCTAssertFalse(view.isHollow)
        view.configure(color: .systemTeal, style: .solid)
        XCTAssertFalse(view.isPulsing)
        XCTAssertFalse(view.isHollow)
    }

    func testOldConfigureStillWorks() {
        let view = AgentDotNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        view.configure(color: .systemTeal, pulses: true)
        XCTAssertTrue(view.isPulsing)
        view.configure(color: .systemTeal, pulses: false)
        XCTAssertFalse(view.isPulsing)
        XCTAssertFalse(view.isHollow, "false is a solid dot")
    }

    /// The pill's dot style: a pulse draws solid unless the panel ticks and Reduce Motion is off.
    func testPulseOnlyWhileTickingWithoutReduceMotion() {
        XCTAssertEqual(AgentDot.drawn(.pulse, ticking: true, reduceMotion: false), .pulse)
        XCTAssertEqual(AgentDot.drawn(.pulse, ticking: false, reduceMotion: false), .solid)
        XCTAssertEqual(AgentDot.drawn(.pulse, ticking: true, reduceMotion: true), .solid)
        XCTAssertEqual(AgentDot.drawn(.hollow, ticking: true, reduceMotion: false), .hollow)
    }

    func testAccessibilitySummaryNamesIndicators() {
        let c = content([act("timer", LivePriority.timerRunning, label: "Timer 4:00 left"),
                         act("music", LivePriority.musicPlaying, label: "Music playing"),
                         act("download", LivePriority.download, label: "Downloading report.pdf")])
        let text = CompactPill.accessibilitySummary(content: c, connection: .connected, platy: .idle)
        XCTAssertTrue(text.contains("Timer 4:00 left"), text)
        XCTAssertTrue(text.contains("Music playing"), text)
        XCTAssertTrue(text.contains("Downloading report.pdf"), text)
        let approvals = CompactPill.accessibilitySummary(content: content([], approvals: 2), connection: .connected,
                                                         platy: nil)
        XCTAssertTrue(approvals.contains("2 waiting for approval"), approvals)
    }

    /// Fix round 1: the summary names how sessions stand, even with Platy off.
    func testSummaryNamesSessionStatesWithoutPlaty() {
        let t = Date(timeIntervalSince1970: 0)
        let waiting = Session(key: "a", agent: "codex", agentName: "Codex", sessionID: "a", state: .waitingInput,
                              startedAt: t, updatedAt: t)
        let text = CompactPill.accessibilitySummary(content: content([], sessions: [waiting]), connection: .connected,
                                                    platy: nil)
        XCTAssertTrue(text.contains("needs you"), text)
        XCTAssertTrue(text.contains("1 agent session"), text)
    }
}
