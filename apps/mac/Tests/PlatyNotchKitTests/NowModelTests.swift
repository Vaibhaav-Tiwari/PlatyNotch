import CoreGraphics
import Foundation
import PlatyNotchKit
import XCTest

final class NowModelTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 4_000_000)

    private func act(_ id: String, _ priority: Int, widget: String, title: String? = nil,
                     countdown: Date? = nil) -> LiveActivity {
        LiveActivity(id: id, widgetID: widget, priority: priority, glyph: .symbol("circle"), countdownTo: countdown,
                     title: title)
    }

    private func ranked(_ activities: [LiveActivity], agents: AgentsLive? = nil) -> [LiveItem] {
        PriorityModel.rank(activities, agents: agents, now: now)
    }

    // MARK: Glance slots

    func testDefaultGlancesAreFirstFour() {
        let slots = GlanceSlots.defaults(glanceCapable: ["meeting", "weather", "system", "wellbeing", "mail"])
        XCTAssertEqual(slots.ids, ["meeting", "weather", "system", "wellbeing"])
        XCTAssertEqual(GlanceSlots.defaults(glanceCapable: ["a"]).ids, ["a"])
    }

    func testSetCapsAndDedupes() {
        var slots = GlanceSlots()
        slots.set(["a", "b", "a", "c", "d", "e"])
        XCTAssertEqual(slots.ids, ["a", "b", "c", "d"])
        XCTAssertEqual(GlanceSlots.limit, 4)
    }

    func testUnavailableGlanceKeepsItsSlot() {
        let slots = GlanceSlots(ids: ["a", "b", "c", "d"])
        XCTAssertEqual(slots.shown(available: ["a", "c", "d"]), ["a", "c", "d"])
        XCTAssertEqual(slots.shown(available: ["a", "b", "c", "d", "e"]), ["a", "b", "c", "d"])
        XCTAssertEqual(slots.ids, ["a", "b", "c", "d"], "the slot itself never changes")
    }

    func testLoadWithoutSavedKeyUsesDefaults() {
        let d = defaults()
        XCTAssertEqual(GlanceSlots.load(from: d, glanceCapable: ["x", "y"]).ids, ["x", "y"])
        var chosen = GlanceSlots()
        chosen.set(["y"])
        chosen.save(to: d)
        XCTAssertEqual(GlanceSlots.load(from: d, glanceCapable: ["x", "y"]).ids, ["y"])
        d.set(Data("junk".utf8), forKey: GlanceSlots.key)
        XCTAssertEqual(GlanceSlots.load(from: d, glanceCapable: ["x"]).ids, ["x"], "unreadable → defaults")
    }

    // MARK: Hero deck

    func testDeckDropsAmbient() {
        let deck = HeroDeck.items(ranked([act("shelf", LivePriority.shelfItems, widget: "shelf"),
                                          act("music", LivePriority.musicPlaying, widget: "music")]))
        XCTAssertEqual(deck.map(\.id), ["music"])
        XCTAssertTrue(HeroDeck.items(ranked([act("shelf", LivePriority.shelfItems, widget: "shelf")])).isEmpty)
    }

    func testOneEntryPerWidget() {
        let agents = AgentsLive(rank: .agentsWorking, title: "Codex · x", subtitle: nil, startedAt: now,
                                needsYou: 0, working: 1, total: 1)
        let deck = HeroDeck.items(ranked([act("timer:1", LivePriority.timerRunning, widget: "time"),
                                          act("timer:2", LivePriority.timerFinished, widget: "time"),
                                          act("music", LivePriority.musicPlaying, widget: "music")], agents: agents))
        XCTAssertEqual(deck.map(\.id), ["timer:2", "agents", "music"])
    }

    func testSelectionSurvivesReorder() {
        let a = ranked([act("t", LivePriority.timerRunning, widget: "time"),
                        act("m", LivePriority.musicPlaying, widget: "music")])
        var hero = HeroDeck()
        XCTAssertEqual(hero.current(in: a), 0)
        hero.step(1, in: a)
        XCTAssertEqual(hero.selectedID, "m")
        let reordered = ranked([act("r", LivePriority.alarmRinging, widget: "alarm"),
                                act("t", LivePriority.timerRunning, widget: "time"),
                                act("m", LivePriority.musicPlaying, widget: "music")])
        XCTAssertEqual(hero.current(in: reordered), 2)
        hero.step(1, in: reordered)
        XCTAssertEqual(hero.selectedID, "r", "wraps")
        hero.step(-1, in: reordered)
        XCTAssertEqual(hero.selectedID, "m", "wraps back")
    }

    func testSelectionFallsBackWhenItemEnds() {
        var hero = HeroDeck()
        let deck = ranked([act("t", LivePriority.timerRunning, widget: "time"),
                           act("m", LivePriority.musicPlaying, widget: "music")])
        hero.step(1, in: deck)
        XCTAssertEqual(hero.current(in: ranked([act("t", LivePriority.timerRunning, widget: "time")])), 0)
        XCTAssertNil(hero.current(in: []))
    }

    func testPanelOpenedResets() {
        var hero = HeroDeck()
        let deck = ranked([act("t", LivePriority.timerRunning, widget: "time"),
                           act("m", LivePriority.musicPlaying, widget: "music")])
        hero.step(1, in: deck)
        hero.panelOpened()
        XCTAssertNil(hero.selectedID)
        XCTAssertEqual(hero.current(in: deck), 0)
    }

    func testPosition() {
        XCTAssertNil(HeroDeck.position(0, of: 0))
        XCTAssertNil(HeroDeck.position(0, of: 1))
        XCTAssertEqual(HeroDeck.position(1, of: 3), "2 of 3")
    }

    // MARK: Modes and lines

    func testApprovalsPendingLineFollowsRank() {
        let deck = HeroDeck.items(ranked([
            act("music", LivePriority.musicPlaying, widget: "music", title: "Music"),
            act("meeting", LivePriority.meetingSoon, widget: "meeting", title: "Design",
                countdown: now.addingTimeInterval(8 * 60)),
        ]))
        XCTAssertEqual(NowMode.resolve(approvals: 1, deck: deck, now: now),
                       .approvalsPending(line: "Now: Design in 8 min · Music"))
        XCTAssertEqual(NowMode.resolve(approvals: 0, deck: deck, now: now), .live)
        XCTAssertEqual(NowMode.resolve(approvals: 0, deck: [], now: now), .summary)
        XCTAssertEqual(NowMode.resolve(approvals: 2, deck: [], now: now), .approvalsPending(line: nil))
        // Rounded up: 7 min 30 s → 8.
        let partial = HeroDeck.items(ranked([act("meeting", LivePriority.meetingSoon, widget: "meeting", title: "Design",
                                                 countdown: now.addingTimeInterval(450))]))
        XCTAssertEqual(NowSummaryLine.text(partial, now: now), "Now: Design in 8 min")
        // A timer's countdown is when it ends: no "in N min".
        let timer = HeroDeck.items(ranked([act("t", LivePriority.timerRunning, widget: "time", title: "Tea",
                                               countdown: now.addingTimeInterval(300))]))
        XCTAssertEqual(NowSummaryLine.text(timer, now: now), "Now: Tea")
    }

    func testQuietLineHidesZeroAndChips() {
        XCTAssertEqual(QuietLine.items(openLoops: 2, tasks: 3, glanceIDs: []),
                       [QuietLineItem(id: "loops", text: "Open loops (2)"), QuietLineItem(id: "reminders", text: "Tasks (3)")])
        XCTAssertEqual(QuietLine.items(openLoops: 0, tasks: 3, glanceIDs: []).map(\.id), ["reminders"])
        XCTAssertEqual(QuietLine.items(openLoops: 2, tasks: 3, glanceIDs: ["reminders"]).map(\.id), ["loops"])
        XCTAssertTrue(QuietLine.items(openLoops: 0, tasks: 0, glanceIDs: []).isEmpty)
    }

    func testDayPhaseBandsAndGreeting() {
        XCTAssertEqual([4, 5, 11, 17, 21].map(DayPhase.at(hour:)), [.night, .morning, .day, .evening, .night])
        XCTAssertEqual(DayPhase.at(hour: 21).greeting, "Hello")
        XCTAssertEqual(DayPhase.morning.greeting, "Good morning")
        XCTAssertEqual(DayPhase.day.greeting, "Good afternoon")
        XCTAssertEqual(DayPhase.evening.greeting, "Good evening")
        XCTAssertEqual(DayPhase.at(hour: 10), .morning)
        XCTAssertEqual(DayPhase.at(hour: 16), .day)
        XCTAssertEqual(DayPhase.at(hour: 20), .evening)
    }

    func testNowFitsTheExpandedPanel() {
        let notched = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                  auxLeft: CGRect(x: 0, y: 944, width: 654, height: 38),
                                  auxRight: CGRect(x: 858, y: 944, width: 654, height: 38))
        XCTAssertTrue(notched.hasNotch)
        XCTAssertEqual(notched.anchor.height, 38)
        let plain = PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), auxLeft: nil, auxRight: nil)
        for layout in [notched, plain] {
            for tour in [false, true] {
                XCTAssertLessThanOrEqual(NowMetrics.required(tourCard: tour), NowMetrics.available(in: layout))
            }
        }
        XCTAssertEqual(NowMetrics.available(in: notched), 380 - 42 - 10)
    }

    func testWidgetKindIsAnOptionSet() {
        let music: WidgetKind = [.live, .tool]
        XCTAssertTrue(music.contains(.live))
        XCTAssertFalse(music.contains(.glance))
        XCTAssertTrue(music.isSuperset(of: .tool))
    }
}
