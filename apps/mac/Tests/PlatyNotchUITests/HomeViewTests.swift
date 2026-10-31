import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class HomeViewTests: DefaultsTestCase {
    private let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelSide
    private let day = Date(timeIntervalSince1970: 1_793_448_000)

    /// Every built-in on (inert), a calendar and reminders, nothing live.
    private func rig(at now: Date? = nil) -> HomeRenders.Rig {
        HomeRenders.builtIns(meeting: false, at: now ?? Date())
    }

    private func data(_ r: HomeRenders.Rig, settings: HomeSettings = HomeSettings(), dropping: Bool = false,
                      airDrop: Bool = true, now: Date = Date()) -> HomeData {
        HomeData.make(today: r.today, widgets: r.registry, settings: settings, tourSample: nil, now: now,
                      dropping: dropping, airDrop: airDrop)
    }

    private func view(_ r: HomeRenders.Rig, settings: HomeSettings = HomeSettings()) -> HomeView {
        HomeView(today: r.today, widgets: r.registry, settings: settings, fixedNow: Date())
    }

    private func size<V: View>(_ v: V) -> CGSize {
        let host = NSHostingView(rootView: v.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark).environment(\.panelTicking, false))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The room Home has: the tallest panel less the inset, the header, the gap and the bottom padding.
    private var room: CGFloat {
        let layout = HomeRenders.layout
        return PanelLayout.expandedHeights.upperBound - layout.contentInset(for: .expanded) - 10
            - HomeMetrics.nav - HomeMetrics.gap
    }

    func testHomeFitsWithEverythingLive() {
        let r = HomeRenders.homeLive()
        for _ in 0..<3 { _ = (r.registry.widget(TimeWidget.widgetID) as? TimeWidget)?.addTimer("9m") }
        let d = data(r)
        XCTAssertEqual(d.chips.count, LiveChips.maxShown)
        XCTAssertGreaterThan(d.overflow, 0)
        XCTAssertEqual(d.rows.count, UpNext.limit)
        XCTAssertLessThanOrEqual(size(view(r)).height, room)
        r.registry.stopAll()
    }

    /// I3: command results never push Home past the 380 pt cap; they scroll inside.
    func testHomeFitsWithCommandResults() {
        let r = HomeRenders.homeLive()
        for _ in 0..<3 { _ = (r.registry.widget(TimeWidget.widgetID) as? TimeWidget)?.addTimer("9m") }
        let model = PanelViewModel()
        model.commandText = "s"
        let tools = ["Sites", "Shelf", "Snap", "Sound"].map { CommandTool(id: $0, title: $0) }
        let logic = CommandLineLogic(model: model, runner: CommandRunner(actions: CommandActions()), tools: { tools })
        XCTAssertGreaterThanOrEqual(logic.suggestions.count, 4)
        let v = HomeView(today: r.today, widgets: r.registry, settings: HomeSettings(), fixedNow: Date(),
                         commandLine: AnyView(CommandLineView(model: model, logic: logic, memory: nil)))
        XCTAssertLessThanOrEqual(size(v).height, room)
        r.registry.stopAll()
    }

    func testRestHeightFitsTheSmallestPanel() {
        let r = HomeRenders.homeRest()
        let h = size(view(r)).height
        XCTAssertLessThanOrEqual(h + HomeMetrics.nav + HomeMetrics.gap, PanelLayout.expandedHeights.upperBound)
        r.registry.stopAll()
    }

    func testNothingPlayingShowsPlaty() {
        let r = rig()
        let texts = HomeView.texts(data(r), nowPlaying: r.today.nowPlaying)
        XCTAssertTrue(texts.contains("Nothing playing"))
        r.registry.stopAll()
    }

    func testPlayingShowsTrack() {
        let r = HomeRenders.musicHero()
        let texts = HomeView.texts(data(r), nowPlaying: r.today.nowPlaying)
        XCTAssertTrue(texts.contains("Weightless"))
        XCTAssertTrue(texts.contains("Marconi Union"))
        XCTAssertFalse(texts.contains("Nothing playing"))
        r.registry.stopAll()
    }

    func testChipsRowHiddenWhenEmpty() {
        let r = rig()
        let quiet = data(r)
        XCTAssertTrue(quiet.chips.isEmpty)
        let live = HomeRenders.homeLive()
        XCTAssertFalse(data(live).chips.isEmpty)
        XCTAssertLessThan(size(view(r)).height, size(view(live)).height, "the row is absent, not blank")
        r.registry.stopAll()
        live.registry.stopAll()
    }

    func testChipTapsRouteToTheirTool() {
        let chips: [LiveChip] = [LiveChip(kind: .focus, text: "Focus 1:00", tone: .needsYou),
                                 LiveChip(kind: .timer(UUID()), text: "Timer 1:00", tone: nil),
                                 LiveChip(kind: .shelf, text: "Shelf · 1", tone: nil)]
        XCTAssertEqual(chips.map(ChipsRow.tool(for:)), [FocusWidget.widgetID, TimeWidget.widgetID, ShelfWidget.widgetID])
    }

    /// The "Try it" sample is a chip that opens nothing, and the row stays at four.
    func testTourSampleChipOpensNothingAndKeepsFour() {
        let r = HomeRenders.homeLive()
        for _ in 0..<3 { _ = (r.registry.widget(TimeWidget.widgetID) as? TimeWidget)?.addTimer("9m") }
        let d = HomeData.make(today: r.today, widgets: r.registry, settings: HomeSettings(), tourSample: TryItSession.sample,
                              now: Date(), dropping: false)
        XCTAssertEqual(d.chips.count, LiveChips.maxShown)
        XCTAssertEqual(d.chips.first?.kind, .sample)
        XCTAssertNil(ChipsRow.tool(for: d.chips[0]))
        XCTAssertGreaterThan(d.overflow, 0)
        r.registry.stopAll()
    }

    func testRightColumnFollowsSetting() {
        let r = rig()
        let notes = HomeSettings(rightColumn: .notes)
        XCTAssertEqual(HomeView.columnID(data(r, settings: notes)), "notes")
        r.registry.setEnabled(NotesWidget.widgetID, false)
        XCTAssertEqual(HomeView.columnID(data(r, settings: notes)), "upNext", "falls back while Notes is off")
        XCTAssertEqual(HomeView.columnID(data(r)), "upNext")
        r.registry.stopAll()
    }

    func testUpNextShowsRows() {
        let r = rig()
        let texts = HomeView.texts(data(r), nowPlaying: r.today.nowPlaying)
        XCTAssertTrue(texts.contains("Up next"))
        XCTAssertTrue(texts.contains("reminder"))
        r.registry.stopAll()
    }

    func testEmptyUpNextSaysSo() {
        let r = HomeRenders.Rig()
        BuiltInWidgets.register(in: r.registry, store: r.store, today: r.today, persist: false)
        r.startAll()
        let texts = HomeView.texts(data(r), nowPlaying: r.today.nowPlaying)
        XCTAssertTrue(texts.contains("Nothing up next"))
        r.registry.stopAll()
    }

    func testDragShowsDropTargets() {
        let r = rig()
        let d = data(r, dropping: true)
        XCTAssertEqual(HomeView.texts(d, nowPlaying: r.today.nowPlaying), ["Drop to keep on Shelf", "AirDrop"])
        r.registry.stopAll()
    }

    /// I4: the chips stay above the box (wireframe B).
    func testDropKeepsTheChips() {
        let r = HomeRenders.homeLive()
        let texts = HomeView.texts(data(r, dropping: true), nowPlaying: r.today.nowPlaying)
        XCTAssertTrue(texts.contains { $0.hasPrefix("Focus") })
        XCTAssertEqual(texts.suffix(2), ["Drop to keep on Shelf", "AirDrop"])
        XCTAssertFalse(texts.contains("Up next"), "the body is the box")
        r.registry.stopAll()
    }

    func testShelfOffDropShowsAirDropOnly() {
        let r = rig()
        r.registry.setEnabled(ShelfWidget.widgetID, false)
        XCTAssertEqual(HomeView.texts(data(r, dropping: true), nowPlaying: r.today.nowPlaying), ["AirDrop"])
        XCTAssertEqual(DropTargetsView.titles(shelfOn: true, airDrop: true), ["Drop to keep on Shelf", "AirDrop"])
        XCTAssertEqual(DropTargetsView.titles(shelfOn: false, airDrop: true), ["AirDrop"])
        XCTAssertEqual(DropTargetsView.titles(shelfOn: true, airDrop: false), ["Drop to keep on Shelf"])
        r.registry.stopAll()
    }

    func testDropZonesSplitTheBox() {
        XCTAssertEqual(DropTargetsView.zone(atX: 100, width: 600, shelfOn: true, airDrop: true), .shelf)
        XCTAssertEqual(DropTargetsView.zone(atX: 500, width: 600, shelfOn: true, airDrop: true), .airDrop)
        XCTAssertEqual(DropTargetsView.zone(atX: 500, width: 600, shelfOn: true, airDrop: false), .shelf)
        XCTAssertEqual(DropTargetsView.zone(atX: 100, width: 600, shelfOn: false, airDrop: true), .airDrop)
        XCTAssertNil(DropTargetsView.zone(atX: 100, width: 600, shelfOn: false, airDrop: false))
    }

    func testLongTitlesTruncate() {
        let long = String(repeating: "Very long title ", count: 13)
        let r = HomeRenders.homeLive()
        r.today.nowPlaying.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: long, artist: long,
                                                     isPlaying: true))
        r.today.calendar.setForTesting(access: .granted, meetings: [
            CalendarMeeting(id: "m", title: long, start: Date().addingTimeInterval(600), end: Date().addingTimeInterval(1800))])
        _ = (r.registry.widget(TimeWidget.widgetID) as? TimeWidget)?.addTimer("9m \(long)")
        let s = size(view(r))
        XCTAssertLessThanOrEqual(s.width, width + 0.5)
        XCTAssertLessThanOrEqual(s.height, room)
        r.registry.stopAll()
    }

    func testControllerAppliesTheReportedHeight() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.debugHandle(.layout(HomeRenders.layout))
        c.bodyHeightReported(150)
        XCTAssertEqual(c.panelModel.layout?.expandedContentHeight, HomeRenders.layout.expandedHeight(forBody: 150))
        c.bodyHeightReported(nil)
        XCTAssertEqual(c.panelModel.layout?.expandedContentHeight, 380, "approvals, a tool or Agents: full height")
        c.bodyHeightReported(20)
        XCTAssertEqual(c.panelModel.layout?.expandedContentHeight, 160, "never shorter than 160")
        r.registry.stopAll()
    }

    /// Final review I1: a content shrink with the pointer in the band it removes (the third
    /// suggestion, the last Agents row) waits, so the hover panel stays open and keeps the
    /// typed command; it applies once the pointer is inside the smaller panel.
    func testShrinkWaitsForThePointer() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.debugHandle(.layout(HomeRenders.layout))
        c.debugHandle(.event(.click))
        XCTAssertEqual(c.panelModel.mode, .expanded)
        c.bodyHeightReported(300)
        let tall = HomeRenders.layout.expandedHeight(forBody: 300)
        XCTAssertEqual(c.panelModel.layout?.expandedContentHeight, tall)
        let big: CGRect = try! XCTUnwrap(c.panelModel.layout).hitRect(for: .expanded)
        // The pointer rests near the bottom edge; typing narrows the list.
        var pointer = CGPoint(x: big.midX, y: big.minY + 6)
        c.cursorLocation = { pointer }
        c.panelModel.commandText = "rem"
        c.bodyHeightReported(150)
        XCTAssertEqual(c.panelModel.layout?.expandedContentHeight, tall, "no shrink under the pointer")
        XCTAssertTrue(c.shrinkPending)
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            c.sampleCursor()
            c.hoverSample(inside: PanelLayout.contains(try! XCTUnwrap(c.panelModel.layout).hitRect(for: .expanded), pointer),
                          at: 1_000 + t)
        }
        XCTAssertEqual(c.panelModel.mode, .expanded, "the panel stays open")
        XCTAssertEqual(c.panelModel.commandText, "rem", "the typed command is kept")
        // The pointer moves up into what stays: the shrink applies, still open.
        pointer = CGPoint(x: big.midX, y: big.maxY - 60)
        c.sampleCursor()
        XCTAssertFalse(c.shrinkPending)
        XCTAssertEqual(c.panelModel.layout?.expandedContentHeight, HomeRenders.layout.expandedHeight(forBody: 150))
        XCTAssertEqual(c.panelModel.mode, .expanded)
        r.registry.stopAll()
    }

    func testHeaderStatusIsDateAndWeather() {
        let fixed = Date(timeIntervalSince1970: 1_793_448_000)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let us = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(PanelHeader<EmptyView, EmptyView>.homeStatus(now: fixed, weather: nil, calendar: cal, locale: us), "Sat 31")
        XCTAssertEqual(PanelHeader<EmptyView, EmptyView>.homeStatus(now: fixed, weather: "14° Clear", calendar: cal, locale: us),
                       "Sat 31 · 14° Clear")
    }

    func testHoverPeekSaysWhatIsLive() {
        XCTAssertEqual(HoverPeekView.lines([]).title, "Nothing live")
        let a = LiveActivity(id: "a", widgetID: "w", priority: 10, glyph: .symbol("timer"), tint: .accent, title: "Low")
        let b = LiveActivity(id: "b", widgetID: "w", priority: 90, glyph: .symbol("timer"), tint: .accent, title: "High",
                             subtitle: "More")
        XCTAssertEqual(HoverPeekView.lines([a, b]).title, "High")
        XCTAssertEqual(HoverPeekView.lines([a, b]).subtitle, "More")
    }

    func testAgentActivityRecordsFinishAndFailure() {
        let model = AgentActivityModel()
        let t = Date(timeIntervalSince1970: 7_000_000)
        func s(_ state: SessionState) -> Session {
            Session(key: "a", agent: "codex", agentName: "Codex", sessionID: "a", state: state, startedAt: t, updatedAt: t)
        }
        var seen: [SessionChanges] = []
        model.observe { seen.append($0) }
        model.sessionsChanged([s(.active)], now: t)
        XCTAssertNil(model.log.lastFinish(now: t))
        model.sessionsChanged([s(.idle)], now: t.addingTimeInterval(5))
        XCTAssertEqual(model.log.lastFinish(now: t.addingTimeInterval(6)), t.addingTimeInterval(5))
        XCTAssertEqual(seen.last?.finished, ["a"])
        model.notice(Notice(kind: "session-failed", title: "Codex stopped with an error", sessionKey: "a"),
                     now: t.addingTimeInterval(6))
        XCTAssertTrue(model.log.failed("a", now: t.addingTimeInterval(7)))
        model.notice(Notice(kind: "info", title: "hello"), now: t.addingTimeInterval(7))
        model.sessionsChanged([s(.active)], now: t.addingTimeInterval(8))
        XCTAssertFalse(model.log.failed("a", now: t.addingTimeInterval(9)), "active again clears the failure")
    }

    func testAgentActivityRerankOnClockChange() {
        let model = AgentActivityModel()
        let before = model.revision
        model.clockChanged(now: Date())
        XCTAssertEqual(model.revision, before + 1)
        let store = AppStore()
        model.start(store: store)
        model.start(store: store)   // idempotent
        model.stop()
    }
}

/// Paused music runs out by itself (an observed change), and at once after a wake or a
/// clock change.
@MainActor
final class MusicPauseExpiryTests: DefaultsTestCase {
    private func music() -> (NowPlaying, MusicWidget) {
        let np = NowPlaying()
        return (np, MusicWidget(nowPlaying: np, visualiser: MusicVisualiser(defaults: defaults())))
    }

    private func info(playing: Bool, title: String = "Song") -> NowPlayingInfo {
        NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: title, artist: "Band", isPlaying: playing)
    }

    func testPauseExpiresAndNotifies() {
        let (np, w) = music()
        np.pauseWindow = 0.3
        np.debugApply(info(playing: true))
        np.debugApply(info(playing: false))
        XCTAssertEqual(w.liveActivities.map(\.id), ["music:paused"])
        let changed = expectation(description: "liveActivities changes when the pause runs out")
        withObservationTracking { _ = w.liveActivities } onChange: { changed.fulfill() }
        wait(for: [changed], timeout: 5)
        XCTAssertNil(np.pausedAt)
        XCTAssertTrue(w.liveActivities.isEmpty)
    }

    func testWakeExpiresAtOnce() {
        let (np, w) = music()
        var now = Date()
        np.pauseClock = { now }
        np.debugApply(info(playing: true), now: now)
        np.debugApply(info(playing: false), now: now)
        XCTAssertNotNil(np.pausedAt)
        now = now.addingTimeInterval(NowPlaying.pauseLength + 60)   // slept through the window
        np.recheckPause()
        XCTAssertNil(np.pausedAt)
        XCTAssertTrue(w.liveActivities.isEmpty)
    }

    func testPlayNewTrackAndNilCancel() {
        let (np, _) = music()
        np.debugApply(info(playing: true))
        np.debugApply(info(playing: false))
        XCTAssertNotNil(np.pausedAt)
        np.debugApply(info(playing: true))
        XCTAssertNil(np.pausedAt, "playing again")
        np.debugApply(info(playing: false))
        np.debugApply(info(playing: false, title: "Next song"))
        XCTAssertNil(np.pausedAt, "a new track loaded paused was not paused by you")
        np.debugApply(info(playing: true))
        np.debugApply(info(playing: false))
        np.debugApply(nil)
        XCTAssertNil(np.pausedAt, "nothing loaded")
    }

    func testActivityRevisionBumpsOnClockChange() {
        let model = AgentActivityModel()
        let before = model.revision
        model.clockChanged(now: Date())
        XCTAssertEqual(model.revision, before + 1)
        let store = AppStore()
        model.start(store: store)
        model.start(store: store)   // idempotent
        model.stop()
    }
}
