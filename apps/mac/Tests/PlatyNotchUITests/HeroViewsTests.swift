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

    private func assertFits(_ hero: AnyView?, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let hero else { return XCTFail("\(id) has no hero", file: file, line: line) }
        let s = size(hero)
        XCTAssertEqual(s.width, width, "\(id) width", file: file, line: line)
        XCTAssertEqual(s.height, NowMetrics.hero, "\(id) height", file: file, line: line)
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
}
