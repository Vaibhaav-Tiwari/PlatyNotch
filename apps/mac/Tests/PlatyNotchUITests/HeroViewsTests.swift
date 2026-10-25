import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class HeroViewsTests: DefaultsTestCase {
    private let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelMargin

    /// The hero laid out in its frame with ‹ › (three items) at Now's width.
    private func size(_ hero: AnyView) -> CGSize {
        let framed = HeroFrame(keyline: nil, position: "2 of 3", onStep: { _ in }) { hero }
        let host = NSHostingView(rootView: framed.frame(width: width).environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The hero content's room inside `HeroFrame` beside ‹ ›: 528 − 2 × 20 − 64 − 8.
    static let contentWidth: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelMargin
        - 2 * Space.heroPadding - HeroFrame<EmptyView>.controlsWidth - Space.s
    static let contentHeight: CGFloat = NowMetrics.hero - 2 * Space.heroPadding

    /// The content's own height at its width, unframed (a frame would hide an overflow).
    static func contentHeight(_ hero: AnyView) -> CGFloat {
        let view = hero.frame(width: contentWidth).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark).environment(\.panelTicking, false)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private func assertFits(_ hero: AnyView?, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let hero else { return XCTFail("\(id) has no hero", file: file, line: line) }
        let s = size(hero)
        XCTAssertEqual(s.width, width, "\(id) width", file: file, line: line)
        XCTAssertEqual(s.height, NowMetrics.hero, "\(id) height", file: file, line: line)
        XCTAssertLessThanOrEqual(Self.contentHeight(hero), Self.contentHeight, "\(id) content overflows",
                                 file: file, line: line)
    }

    /// Where the primary control lands in a hero `contentWidth` wide.
    static func actionFrame(_ hero: some View) -> (frame: CGRect?, size: CGSize) {
        var found: CGRect?
        let view = hero.frame(width: contentWidth)
            .onPreferenceChange(HeroActionFrameKey.self) { found = $0 }
            .environment(\.colorScheme, .dark).environment(\.panelTicking, false)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return (found, host.fittingSize)
    }

    func testPrimaryControlStaysInsideWithLongTitle() {
        let long = String(repeating: "x", count: 200)
        let hero = HeroLayout(title: long, subtitle: long,
                              action: HeroAction(title: "Open terminal", systemImage: "terminal", run: {})) {
            HeroGlyph(glyph: .symbol("timer"), tint: .accent)
        } value: {
            HeroClock(countdownTo: Date().addingTimeInterval(252), countUpFrom: nil)
        }
        let (frame, size) = Self.actionFrame(hero)
        XCTAssertNotNil(frame, "the control reported its frame")
        let control = frame
        let content = CGRect(x: 0, y: 0, width: Self.contentWidth, height: size.height)
        if let control {
            XCTAssertTrue(content.insetBy(dx: -0.5, dy: -0.5).contains(control), "\(control) outside \(content)")
            XCTAssertGreaterThan(control.width, 60, "the control keeps its label")
        }
        XCTAssertLessThanOrEqual(size.height, Self.contentHeight)
        // Without a value the title may take two lines and still fit.
        let noValue = HeroLayout(title: long, subtitle: long,
                                 action: HeroAction(title: "Stop", systemImage: "stop.fill", run: {})) {
            HeroGlyph(glyph: .symbol("alarm"), tint: .critical)
        }
        XCTAssertLessThanOrEqual(Self.contentHeight(AnyView(noValue)), Self.contentHeight)
        XCTAssertLessThanOrEqual(Self.contentHeight(AnyView(GenericHero(item: LiveItem(
            id: "x", rank: .minor, source: .activity(LiveActivity(id: "x", widgetID: "w", priority: 20,
                                                                  glyph: .symbol("cup.and.saucer.fill"), title: long,
                                                                  subtitle: long)),
            title: long, subtitle: long, startedAt: nil, countdownTo: nil)))), Self.contentHeight)
    }

    /// Ruling: the title gets the text column's full width, so a normal agent title shows
    /// in full beside Platy with the button below it.
    func testAgentsTitleShowsInFull() {
        let agents = AgentsLive(rank: .agentsWorking, title: "Claude Code · platynotch", subtitle: "Running tests",
                                startedAt: Date(), needsYou: 0, working: 2, total: 2, leadKey: "a", leadAttention: .working)
        let title = Text(verbatim: agents.title).font(DS.font(TypeScale.title)).fixedSize()
        let host = NSHostingView(rootView: title)
        host.layoutSubtreeIfNeeded()
        let room: CGFloat = Self.contentWidth - 96 - Space.l
        XCTAssertLessThanOrEqual(host.fittingSize.width, room, "the title fits beside Platy")
    }

    func testErroredLeadShowsTheErrorState() {
        let errored = AgentsLive(rank: .agentNeedsYou, title: "Codex · api", subtitle: "Stopped with an error",
                                 startedAt: Date(), needsYou: 1, working: 0, total: 1, leadKey: "e", leadAttention: .errored)
        XCTAssertEqual(AgentsHero.tone(for: errored), .error, "coral, not amber")
        XCTAssertEqual(AgentsHero.action(for: errored), .openTerminal)
        let finishedWithWork = AgentsLive(rank: .agentFinished, title: "Codex · api", subtitle: "Finished",
                                          startedAt: Date(), needsYou: 0, working: 1, total: 2, leadKey: "f",
                                          leadAttention: .finished)
        XCTAssertEqual(AgentsHero.tone(for: finishedWithWork), .done)
        XCTAssertEqual(AgentsHero.action(for: finishedWithWork), .openTerminal)
    }

    func testPrimaryButtonContrast() {
        for dark in [true, false] {
            let c = HeroPrimaryButtonStyle.colors(dark: dark)
            XCTAssertGreaterThanOrEqual(RGB.contrast(c.label, c.fill), 4.5, dark ? "dark" : "light")
        }
    }

    func testClockSpeaksInWords() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(HeroClock.spoken(countdownTo: now.addingTimeInterval(252), countUpFrom: nil, style: .clock, now: now),
                       "4 minutes 12 seconds left")
        XCTAssertEqual(HeroClock.spoken(countdownTo: nil, countUpFrom: now.addingTimeInterval(-3725), style: .clock,
                                        now: now), "1 hour 2 minutes 5 seconds elapsed")
        XCTAssertEqual(HeroClock.spoken(countdownTo: now.addingTimeInterval(450), countUpFrom: nil, style: .minutesUntil,
                                        now: now), "starts in 8 minutes")
        XCTAssertEqual(NowSummaryLine.inMinutes(to: now.addingTimeInterval(450), now: now), "in 8 min")
    }

    func testEveryLiveBuiltInHasAHero() {
        let d = defaults()
        let long = String(repeating: "A very long title ", count: 12)

        let np = NowPlaying()
        np.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: long, artist: long, isPlaying: true))
        let music = MusicWidget(nowPlaying: np, visualiser: MusicVisualiser(defaults: d))
        XCTAssertEqual(music.liveActivities.count, 1)
        assertFits(music.heroView(), "music")

        let time = TimeWidget(defaults: d, persist: false)
        XCTAssertTrue(time.addTimer("5m"))
        XCTAssertFalse(time.liveActivities.isEmpty)
        assertFits(time.heroView(), "time")
        let timerActivity = time.liveActivities.first { $0.id.hasPrefix("time:timer:") }
        XCTAssertEqual(timerActivity.flatMap { time.heroAction($0) }?.title, "Pause")

        let calendar = CalendarService(eventKit: false)
        let now = Date()
        let start = now.addingTimeInterval(5 * 60)
        calendar.setForTesting(access: .granted, meetings: [
            CalendarMeeting(id: "m", title: long, start: start, end: start.addingTimeInterval(1800),
                            joinURL: URL(string: "https://meet.example.com/abc")),
        ])
        let meeting = MeetingWidget(calendar: calendar, defaults: d, clock: { now })
        XCTAssertFalse(meeting.liveActivities.isEmpty)
        assertFits(meeting.heroView(), "meeting")

        let focusModel = FocusModel(defaults: d)
        focusModel.start(minutes: 25)
        let focus = FocusWidget(focus: focusModel)
        XCTAssertFalse(focus.liveActivities.isEmpty)
        assertFits(focus.heroView(), "focus")

        let shelf = ShelfWidget.inert()
        shelf.actionCenter.debugSetRunning([UUID(): .init(action: .zip, title: long)])
        assertFits(shelf.heroView(), "shelf")

        // Nothing live in these inert ones: the hero lays out empty, still inside the frame.
        assertFits(SystemWidget.inert().heroView(), "system")
        assertFits(MirrorWidget.inert().heroView(), "mirror")
        assertFits(GamesWidget.inert().heroView(), "games")
        focusModel.stop()
    }

    func testAgentsHeroUsesRowAction() {
        let t = Date()
        let needs = AgentsLive(rank: .agentNeedsYou, title: "Claude Code · platynotch", subtitle: "Needs your input",
                               startedAt: t, needsYou: 1, working: 2, total: 3)
        let working = AgentsLive(rank: .agentsWorking, title: "Codex · api", subtitle: "Running tests",
                                 startedAt: t, needsYou: 0, working: 1, total: 1)
        XCTAssertEqual(AgentsHero.action(for: needs).title, "Answer")
        XCTAssertEqual(AgentsHero.action(for: working).title, "Open terminal")
        var tapped = 0
        let hero = AgentsHero(agents: needs, action: AgentsHero.action(for: needs), mood: .waiting) { tapped += 1 }
        hero.onPrimary()
        XCTAssertEqual(tapped, 1)
        assertFits(AnyView(hero.environment(\.panelTicking, false)), "agents")
        let long = String(repeating: "project ", count: 30)
        let longHero = AgentsHero(agents: AgentsLive(rank: .agentsWorking, title: long, subtitle: long, startedAt: t,
                                                     needsYou: 0, working: 12, total: 12),
                                  action: .openTerminal, mood: .working, onPrimary: {})
        assertFits(AnyView(longHero.environment(\.panelTicking, false)), "agents (long)")
    }

    /// Fix round 1: the agents hero's counts never truncate. At the hover peek's width
    /// (420 − 2 × 12) the lead state alone shows; at Now's width the full counts.
    func testAgentsCountsFitTheHoverPeek() {
        let agents = AgentsLive(rank: .agentsWorking, title: "Claude Code · platynotch", subtitle: "Running tests",
                                startedAt: Date(), needsYou: 0, working: 2, total: 2)
        func shown(width: CGFloat) -> AgentsCountsShown? {
            var found: AgentsCountsShown?
            let framed = HeroFrame(keyline: nil, position: nil, onStep: nil) {
                AgentsHero(agents: agents, action: .openTerminal, mood: .working) {}
            }
            let view = framed.frame(width: width)
                .onPreferenceChange(AgentsCountsShownKey.self) { found = $0 }
                .environment(\.colorScheme, .dark).environment(\.panelTicking, false)
            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            return found
        }
        XCTAssertEqual(shown(width: PanelLayout.peekSize.width - 24), .short)
        XCTAssertEqual(shown(width: width), .full)
        let hero = AgentsHero(agents: agents, action: .openTerminal, mood: nil) {}
        XCTAssertEqual(hero.shortCounts, "2 working")
    }
}
