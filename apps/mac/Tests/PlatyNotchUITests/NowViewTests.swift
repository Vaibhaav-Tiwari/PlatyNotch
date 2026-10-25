import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// A widget that is live and a glance, for Now's fit tests.
@MainActor
private final class NowFakeWidget: NotchWidget {
    let id: String
    let title: String
    let systemImage = "star"
    let defaultEnabled = true
    let kind: WidgetKind
    var live: [LiveActivity] = []
    var liveActivities: [LiveActivity] { live }

    init(_ id: String, kind: WidgetKind, title: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title ?? id.capitalized
    }

    func tileView() -> AnyView { AnyView(Text(verbatim: title)) }
    func glanceView() -> AnyView? {
        kind.contains(.glance) ? AnyView(GlanceChip(systemImage: "star", value: "42", label: title)) : nil
    }
}

/// A battery at 82 %.
@MainActor
private final class BatteryPower: PowerSourceReading {
    func read() -> BatteryState? { BatteryState(percent: 82, charging: false, pluggedIn: false, minutesRemaining: nil) }
    func start(onChange: @escaping @MainActor () -> Void) {}
    func stop() {}
}

/// A glance widget that is off by default.
@MainActor
private final class OffGlance: NotchWidget {
    let id: String
    let title = "Off"
    let systemImage = "star"
    let defaultEnabled = false
    var kind: WidgetKind { [.glance, .tool] }
    init(_ id: String) { self.id = id }
    func tileView() -> AnyView { AnyView(EmptyView()) }
}

@MainActor
final class NowViewTests: DefaultsTestCase {
    /// A 14-inch MacBook Pro with a 38 pt camera housing.
    private var notched38: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
                    auxLeft: CGRect(x: 0, y: 944, width: 654, height: 38),
                    auxRight: CGRect(x: 858, y: 944, width: 654, height: 38))
    }

    private var plain: PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055), auxLeft: nil, auxRight: nil)
    }

    /// The width Now gets inside the open panel (560 less the 16 pt margins).
    private let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelMargin

    private struct Rig {
        let store: AppStore
        let registry: WidgetRegistry
        let today: TodayServices
    }

    /// Every built-in on (inert), plus fakes that make four glances and three live items.
    private func rig(longTitles: Bool = false) -> Rig {
        let store = AppStore()
        let loop = Loop(id: "l1", title: "Reply to Priya", kind: "promise", status: "open", detectedAt: Date())
        try? store.apply(Envelope.make(.snapshot, Snapshot(loops: [loop])))
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, nowPlaying: NowPlaying(),
                                  visualiser: MusicVisualiser(defaults: defaults()),
                                  calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        BuiltInWidgets.register(in: registry, store: store, today: today, persist: false)
        let long = String(repeating: "Very long title ", count: 13)
        for (i, id) in ["fake.a", "fake.b", "fake.c"].enumerated() {
            let w = NowFakeWidget(id, kind: [.live, .glance, .tool], title: longTitles ? long : nil)
            w.live = [LiveActivity(id: "\(id):1", widgetID: id, priority: LivePriority.timerRunning - i * 10,
                                   glyph: .symbol("timer"), title: longTitles ? long : "Item \(i)",
                                   subtitle: longTitles ? long : "Subtitle")]
            registry.register(w)
        }
        registry.register(NowFakeWidget("fake.d", kind: [.glance, .tool]))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnnow\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: store, client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              surfaces: PanelSurfaces(registry: registry), openPanel: { _ in }))
        for w in registry.orderedWidgets { registry.setEnabled(w.id, true) }
        var slots = GlanceSlots()
        slots.set(["fake.a", "fake.b", "fake.c", "fake.d"])
        slots.save(to: defaults())
        return Rig(store: store, registry: registry, today: today)
    }

    private func now(_ r: Rig) -> some View {
        NowView(store: r.store, widgets: r.registry, today: r.today, deck: .constant(HeroDeck()),
                glanceDefaults: defaults(), onOpenTool: { _ in }, onOpenAgents: {}, onOpenTerminal: { _ in })
    }

    private func height<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testNowFitsWithEverythingOn() {
        let r = rig()
        XCTAssertEqual(r.registry.rankedLive(agents: nil, now: Date()).count, 3)
        XCTAssertGreaterThanOrEqual(r.registry.glanceWidgets.count, 4, "more glances than slots")
        let h = height(now(r))
        let full: CGFloat = NowMetrics.hero + NowMetrics.gap + NowMetrics.glance + NowMetrics.gap + NowMetrics.quietLine
        XCTAssertEqual(h, full, accuracy: 0.5, "hero, four glances and the quiet line")
        for layout in [notched38, plain] {
            XCTAssertLessThanOrEqual(NowMetrics.nav + NowMetrics.gap + h, NowMetrics.available(in: layout),
                                     "Now never scrolls (\(layout.hasNotch ? "38 pt notch" : "no notch"))")
        }
        // Long titles on the hero and the chips change nothing.
        XCTAssertEqual(height(now(rig(longTitles: true))), h, accuracy: 0.5)
    }

    func testIdleSummaryFits() {
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let view = NowView(store: store, widgets: registry, today: today, deck: .constant(HeroDeck()),
                           glanceDefaults: defaults(), onOpenTool: { _ in }, onOpenAgents: {}, onOpenTerminal: { _ in })
        let h = height(view)
        XCTAssertGreaterThanOrEqual(h, NowMetrics.hero)
        XCTAssertLessThanOrEqual(NowMetrics.nav + NowMetrics.gap + h, NowMetrics.available(in: notched38))
    }

    func testApprovalCollapsesNowToOneLine() throws {
        let r = rig()
        let created = Date()
        try r.store.apply(Envelope.make(.approvalAdded, Approval(
            id: "a", sessionKey: "s", agent: "claude-code", agentName: "Claude Code", project: nil, cwd: nil,
            tool: "Bash", summary: "ls", createdAt: created, expiresAt: created.addingTimeInterval(600))))
        XCTAssertLessThanOrEqual(height(now(r)), NowMetrics.quietLine + 4, "one compact line, no hero, no glances")
    }

    /// While an approval is pending: nav, gap, the approvals region at its 240 pt cap, gap
    /// and the one compact line still fit beside a 38 pt notch.
    func testApprovalsPendingFits() {
        let needed: CGFloat = NowMetrics.nav + NowMetrics.gap + 240 + NowMetrics.gap + NowMetrics.quietLine
        XCTAssertLessThanOrEqual(needed, NowMetrics.available(in: notched38))
        XCTAssertLessThanOrEqual(needed, NowMetrics.available(in: plain))
    }

    /// Ruling 6: the default slots are saved once from every registered glance; turning the
    /// first glance off hides its chip without pulling in a fifth, and turning it back on
    /// puts it back first.
    func testGlancesNeverBackfill() {
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let ids = ["g1", "g2", "g3", "g4", "g5"]
        for id in ids { registry.register(NowFakeWidget(id, kind: [.glance, .tool])) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnglance\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: store, client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              openPanel: { _ in }))
        func shown() -> [String] {
            NowView.glanceEntries(widgets: registry, usage: store.usage, defaults: defaults()).map(\.id)
        }
        // The first one is off before Now ever resolves the slots: it still owns slot 1.
        registry.setEnabled("g1", false)
        XCTAssertEqual(shown(), ["g2", "g3", "g4"])
        XCTAssertEqual(GlanceSlots.load(from: defaults(), glanceCapable: []).ids, ["g1", "g2", "g3", "g4"], "saved once")
        registry.setEnabled("g1", true)
        XCTAssertEqual(shown(), ["g1", "g2", "g3", "g4"])
        registry.setEnabled("g1", false)
        XCTAssertEqual(shown(), ["g2", "g3", "g4"], "no g5: nothing backfills")
        registry.setEnabled("g1", true)
        XCTAssertEqual(shown(), ["g1", "g2", "g3", "g4"], "back first")
    }

    /// A new user's slots: the glances on by default in registry order (meeting, loops,
    /// System's battery), then usage; with content in each, four chips show.
    func testStockDefaultsShowFourChips() {
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        // The real built-ins give this order.
        let stock = WidgetRegistry(defaults: defaults(), persist: false)
        BuiltInWidgets.register(in: stock, store: store, today: today, persist: false)
        let expected = [MeetingWidget.widgetID, LoopsWidget.widgetID, SystemWidget.widgetID, GlanceSlots.usageID]
        XCTAssertEqual(Array(stock.defaultGlanceOrder.prefix(4)), expected)

        // The glance widgets in the built-ins' order, each with content (System with a battery).
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(MeetingWidget(calendar: today.calendar, defaults: defaults()))
        registry.register(LoopsWidget(store: store, actions: today.loops))
        registry.register(RemindersWidget.inert())
        registry.register(WeatherWidget.inert())
        registry.register(WellbeingWidget.inert())
        registry.register(SystemWidget(power: BatteryPower(), asserter: NoPowerAsserter(), headphones: NoHeadphones(),
                                       downloads: .none, defaults: defaults(), persist: false))
        registry.register(MailWidget.inert())
        XCTAssertEqual(Array(registry.defaultGlanceOrder.prefix(4)), expected)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnstock\(UUID().uuidString)")
        registry.start(context: WidgetContext(store: store, client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                              openPanel: { _ in }))
        let start = Date().addingTimeInterval(3600)
        today.calendar.setForTesting(access: .granted, meetings: [
            CalendarMeeting(id: "m", title: "Design", start: start, end: start.addingTimeInterval(1800)),
        ])
        let loop = Loop(id: "l", title: "Reply", kind: "promise", status: "open", detectedAt: Date())
        let json = #"{"claude":{"five_hour":{"used_percent":40},"updated_at":"2026-10-25T09:00:00Z"}}"#
        let usage = try? JSONCoding.decoder.decode(Usage.self, from: Data(json.utf8))
        try? store.apply(Envelope.make(.snapshot, Snapshot(usage: usage ?? Usage(), loops: [loop])))
        let shown = NowView.glanceEntries(widgets: registry, usage: store.usage, defaults: defaults()).map(\.id)
        XCTAssertEqual(shown, expected, "four chips for a new user")
        XCTAssertEqual(GlanceSlots.load(from: defaults(), glanceCapable: []).ids, expected, "saved once")
        registry.stopAll()
    }

    /// Fewer than four on by default: the other registered glances fill the rest.
    func testDefaultsFillFromOtherGlances() {
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registry.register(NowFakeWidget("on", kind: [.glance]))
        let offA = OffGlance("offA"), offB = OffGlance("offB"), offC = OffGlance("offC")
        [offA, offB, offC].forEach { registry.register($0) }
        XCTAssertEqual(Array(registry.defaultGlanceOrder.prefix(4)), ["on", GlanceSlots.usageID, "offA", "offB"])
        let slots = GlanceSlots.resolve(from: defaults(), glanceCapable: registry.defaultGlanceOrder)
        XCTAssertEqual(slots.ids, ["on", GlanceSlots.usageID, "offA", "offB"])
    }

    func testHeroFitsWithLongTitle() {
        let long = String(repeating: "x", count: 200)
        let item = LiveItem(id: "x", rank: .timerRunning,
                            source: .activity(LiveActivity(id: "x", widgetID: "w", priority: 55, glyph: .symbol("timer"))),
                            title: long, subtitle: long, startedAt: nil, countdownTo: nil)
        let hero = HeroFrame(keyline: nil, position: "2 of 3", onStep: { _ in }) {
            GenericHero(item: item)
        }
        let host = NSHostingView(rootView: hero.frame(width: width).environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, NowMetrics.hero)
        XCTAssertEqual(host.fittingSize.width, width)
        // The ‹ › column keeps its full width beside the truncated text.
        XCTAssertGreaterThan(HeroFrame<EmptyView>.controlsWidth, 0)
        let controls = NSHostingView(rootView: HeroControls(position: "2 of 3", onStep: { _ in }).fixedSize())
        controls.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(controls.fittingSize.width, HeroFrame<EmptyView>.controlsWidth)
    }

    func testDefaultRouteIsNow() {
        XCTAssertEqual(PanelViewModel().route, PanelRoute(destination: .now))
        XCTAssertEqual(PanelRoute.legacy(tab: BuiltinTab.now, tools: []), PanelRoute(destination: .now))
        let store = AppStore()
        let client = CoreClient(socketPath: "/nonexistent")
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        var route = PanelViewModel().route
        let panel = ExpandedPanel(store: store, responder: ApprovalResponder(client: client), arming: ApprovalArming(),
                                  today: today, widgets: WidgetRegistry(defaults: defaults(), persist: false),
                                  memory: MemoryServices(client: client), extraTabs: [],
                                  route: Binding(get: { route }, set: { route = $0 }),
                                  onCollapse: {}, onDecide: { _, _ in }, onOpenTerminal: { _ in })
        XCTAssertEqual(panel.destinations.first, .now)
        XCTAssertEqual(panel.destinations, [.now, .agents, .library])
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

    func testNoScrollViewInNow() throws {
        let dir = DesignLintTests.uiSources.appendingPathComponent("Now")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 7)
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            XCTAssertFalse(code.contains("ScrollView"), "\(url.lastPathComponent) scrolls")
            XCTAssertFalse(code.contains("List {"), "\(url.lastPathComponent) scrolls")
        }
    }
}

@MainActor
final class GlanceRowTests: DefaultsTestCase {
    /// Four chips and their gaps fill the content width exactly: never wider.
    func testFourChipsFitTheWidth() {
        let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelMargin
        let entries = (0..<4).map { i in
            GlanceEntry(id: "g\(i)", view: AnyView(GlanceChip(systemImage: "star",
                                                               value: String(repeating: "9", count: 40),
                                                               label: String(repeating: "Label ", count: 20))))
        }
        let host = NSHostingView(rootView: GlanceRow(entries: entries, onOpen: { _ in }).fixedSize())
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5)
        XCTAssertEqual(host.fittingSize.height, NowMetrics.glance)
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
