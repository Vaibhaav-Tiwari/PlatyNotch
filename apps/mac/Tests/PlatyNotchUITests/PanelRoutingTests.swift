import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Records each `@State` token its probe view was drawn with (a new token: torn down).
@MainActor
private final class StateRecord {
    var tokens: Set<UUID> = []
    var inTool: [Bool] = []
}

/// Made once per view identity (`@StateObject` builds it lazily, so a rebuilt view gets a new one).
private final class StateToken: ObservableObject {
    let id = UUID()
}

private struct StateProbe: View {
    let record: StateRecord
    let height: CGFloat
    @StateObject private var state = StateToken()
    @Environment(\.inPanelTool) private var inTool

    var body: some View {
        MainActor.assumeIsolated {
            record.tokens.insert(state.id)
            record.inTool.append(inTool)
        }
        return Color.clear.frame(height: height)
    }
}

/// The open panel has two destinations; today's tabs and plugin tabs are features that open
/// full-panel inside Home with a back chevron (spec 2, 2.4, 7).
@MainActor
final class PanelRoutingTests: DefaultsTestCase {
    private struct Rig {
        let store: AppStore
        let client: CoreClient
        let registry: WidgetRegistry
        let today: TodayServices
    }

    private func rig(started: Bool = true, extra: [any NotchWidget] = []) -> Rig {
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        let today = TodayServices(client: client, calendar: CalendarService(eventKit: false),
                                  reminders: RemindersService(eventKit: false, defaults: defaults()),
                                  focus: FocusModel(defaults: defaults()))
        let store = AppStore()
        BuiltInWidgets.register(in: registry, store: store, today: today, persist: false)
        for w in extra { registry.register(w) }
        if started {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnlib\(UUID().uuidString)")
            registry.start(context: WidgetContext(store: store, client: client,
                                                  config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                                  events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                                                  surfaces: PanelSurfaces(registry: registry), openPanel: { _ in }))
        }
        return Rig(store: store, client: client, registry: registry, today: today)
    }

    private func panel(_ r: Rig, tabs: [PanelTab] = [], route: PanelRoute = PanelRoute(destination: .home),
                       agentsVisible: Bool = true) -> ExpandedPanel {
        var current = route
        return ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                             today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                             extraTabs: tabs, route: Binding(get: { current }, set: { current = $0 }),
                             onCollapse: {}, agentsVisible: agentsVisible,
                             onDecide: { _, _ in }, onOpenTerminal: { _ in })
    }

    private let pluginTab = PanelTab(id: "fake.tab", title: "Fake", systemImage: "puzzlepiece") { Text("plugin") }

    func testNavHasTwoDestinations() {
        XCTAssertEqual(ExpandedPanel.destinations(agentsVisible: true), [.home, .agents])
        XCTAssertEqual(ExpandedPanel.destinations(agentsVisible: false), [.home])
        let p = panel(rig(), tabs: [pluginTab])
        XCTAssertEqual(p.destinations, [.home, .agents], "plugin tabs never add a destination")
    }

    /// Focus, Memory and Games (with Platy Chase beside it) and plugin tabs all open inside
    /// Home, in catalog order.
    func testEveryOldTabHasAHome() {
        let ids = panel(rig(), tabs: [pluginTab]).panelTools.map(\.id)
        for id in [FocusWidget.widgetID, PanelTools.memory, GamesWidget.widgetID, PanelTools.chase,
                   PanelTools.plugin("fake.tab")] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let games = ids.firstIndex(of: GamesWidget.widgetID)!
        XCTAssertEqual(ids[games + 1], PanelTools.chase, "Platy Chase right after Games")
        XCTAssertEqual(ids.suffix(2), [PanelTools.memory, PanelTools.plugin("fake.tab")], "then Memory, then plugins")
        // Every tool opens to a view.
        for tool in panel(rig(), tabs: [pluginTab]).panelTools {
            let host = NSHostingView(rootView: tool.view().frame(width: 528, height: 280))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0, tool.id)
        }
    }

    /// `expand(tab:)` keeps its signature and maps through `PanelRoute.legacy`.
    func testLegacyExpandRoutes() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry,
                                extraTabs: [pluginTab])
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        c.expand(tab: "memory")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: PanelTools.memory))
        c.expand(tab: BuiltinTab.today)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        c.expand(tab: BuiltinTab.games)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: GamesWidget.widgetID))
        c.expand(tab: "fake.tab")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: "plugin:fake.tab"))
        c.expand(tab: "music")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: "music"))
        c.expand(tab: BuiltinTab.agents)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .agents))
    }



    func testDisabledWidgetsNotListed() {
        let r = rig()
        XCTAssertTrue(panel(r).panelTools.contains { $0.id == "music" })
        r.registry.setEnabled("music", false)
        XCTAssertFalse(panel(r).panelTools.contains { $0.id == "music" })
        r.registry.setEnabled(GamesWidget.widgetID, false)
        let ids = panel(r).panelTools.map(\.id)
        XCTAssertFalse(ids.contains(GamesWidget.widgetID))
        XCTAssertFalse(ids.contains(PanelTools.chase), "Platy Chase goes with Games")
        XCTAssertTrue(ids.contains(PanelTools.memory))
    }

    /// Chips open their tool directly (through Home's `onOpenTool`).
    func testChipLinksOpenTheirTool() {
        XCTAssertEqual(ExpandedPanel.route(forTool: "loops"), PanelRoute(destination: .home, tool: "loops"))
        let r = rig()
        var route = PanelRoute(destination: .home)
        let p = ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                              today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                              extraTabs: [], route: Binding(get: { route }, set: { route = $0 }),
                              onCollapse: {}, onDecide: { _, _ in }, onOpenTerminal: { _ in })
        p.homeView.onOpenTool(LoopsWidget.widgetID)
        XCTAssertEqual(route, PanelRoute(destination: .home, tool: LoopsWidget.widgetID))
        p.homeView.onOpenTool(FocusWidget.widgetID)
        XCTAssertEqual(route, PanelRoute(destination: .home, tool: FocusWidget.widgetID))
    }

    /// The tool header: back chevron with its VoiceOver name, and the tool's title.
    func testToolHostHasABackChevron() {
        var backs = 0
        let host = ToolHost(title: "Memory", onBack: { backs += 1 }, content: AnyView(Text("x")))
        XCTAssertEqual(ToolHost.backLabel, "Back to Home")
        host.onBack()
        XCTAssertEqual(backs, 1)
        let v = NSHostingView(rootView: host.frame(width: 528, height: 288))
        v.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(v.fittingSize.width, 0)
    }

    /// The games tool fits the room a tool has below its header on a 38 pt notch.
    func testGamesFitAsATool() {
        XCTAssertNil(AppDelegate.checkGameViews())
        XCTAssertLessThanOrEqual(GameLayout.tabSize.height, ToolHost.contentHeight(available: 380 - 42 - 10))
    }

    /// ⌘1 and ⌘2 only, never Return or a digit alone.
    func testCommandDigits() throws {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 18) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(NotchPanel.commandDigit(try key("1", .command)), 1)
        XCTAssertEqual(NotchPanel.commandDigit(try key("2", .command)), 2)
        XCTAssertNil(NotchPanel.commandDigit(try key("3", .command)), "the Library's ⌘3 is gone")
        XCTAssertNil(NotchPanel.commandDigit(try key("4", .command)))
        XCTAssertNil(NotchPanel.commandDigit(try key("1", [])), "a digit alone types")
        XCTAssertNil(NotchPanel.commandDigit(try key("1", [.command, .shift])))
        XCTAssertNil(NotchPanel.commandDigit(try key("\r", .command, code: 36)), "never Return")
        XCTAssertNil(NotchPanel.commandDigit(try key("\r", [], code: 36)))
    }

    /// ⌘1 reaches the panel's handler only while the panel is the key window.
    func testNonKeyPanelIgnoresCommandDigit() throws {
        let panel = NotchPanel(frame: CGRect(x: -10_000, y: 10_000, width: 10, height: 10))
        var digits: [Int] = []
        panel.onCommandDigit = { digits.append($0); return true }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: 0, windowNumber: 0, context: nil, characters: "1",
                                                   charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(panel.performKeyEquivalent(with: event))
        XCTAssertEqual(digits, [], "a panel without the keyboard never takes the shortcut")
    }

    /// ⌘1 / ⌘2 switch destinations in the open panel, also from inside a tool.
    func testCommandDigitsSwitchDestinations() {
        let r = rig()
        AgentsVisibility(forcedOn: true).save(to: defaults())
        r.today.agentActivity.loadVisibility(from: defaults())
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        XCTAssertFalse(c.commandDigit(1), "only in the open panel")
        c.expand(tab: "memory")
        XCTAssertEqual(c.mode, .expanded)
        XCTAssertTrue(c.commandDigit(2))
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .agents))
        XCTAssertTrue(c.commandDigit(1))
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        XCTAssertFalse(c.commandDigit(3))
        XCTAssertFalse(c.commandDigit(4))
        // Agents hidden: ⌘2 does nothing.
        let hidden = rig()
        let h = NotchController(store: hidden.store, client: hidden.client, plugins: [], today: hidden.today,
                                widgets: hidden.registry)
        h.expand()
        XCTAssertFalse(h.commandDigit(2))
        XCTAssertEqual(h.panelModel.route, PanelRoute(destination: .home))
    }

    /// Esc goes back from a tool to Home first, then closes the panel.
    func testEscapeGoesBackBeforeClosing() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.expand(tab: "memory")
        XCTAssertEqual(c.mode, .expanded)
        c.escapePressed()
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        XCTAssertEqual(c.mode, .expanded, "the first Esc only leaves the tool")
        c.escapePressed()
        XCTAssertNotEqual(c.mode, .expanded, "then Esc closes the panel")
    }

    /// Fix round 1: the room changing between "fits" and "scrolls" never rebuilds the tool,
    /// so its `@State` (typed text, a picker's choice, focus) survives.
    func testToolStateSurvivesAHeightChange() {
        let record = StateRecord()
        let body = ToolBody(content: AnyView(StateProbe(record: record, height: 200)))
        let host = NSHostingView(rootView: body)
        // Off screen, never where the user works; a window so size changes re-lay out.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: 528, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        for height in [400.0, 120.0, 400.0, 80.0] as [CGFloat] {
            window.setFrame(CGRect(x: -10_000, y: 10_000, width: 528, height: height), display: true)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(record.tokens.count, 1, "the tool kept its state through fits and scrolls")
        XCTAssertFalse(record.inTool.isEmpty)
        XCTAssertTrue(record.inTool.allSatisfy { $0 }, "ToolBody tells the tool it is full-panel")
    }

    // MARK: Fix round 1: needsSetup, setup actions and the Chase entry

    /// Calendar and Reminders: only "not asked" and "refused" are setup; "unavailable"
    /// (no usage description, EventKit off) is not something the user can set up.
    func testNeedsSetupForCalendarAndReminders() {
        let table: [(CalendarService.Access, Bool)] = [(.notAsked, true), (.denied, true), (.granted, false),
                                                       (.unavailable, false)]
        for (access, expected) in table {
            XCTAssertEqual(MeetingWidget.needsSetup(access: access), expected, "\(access)")
            let calendar = CalendarService(eventKit: false)
            calendar.setForTesting(access: access, meetings: [])
            let meeting = MeetingWidget(calendar: calendar)
            XCTAssertEqual(meeting.needsSetup, expected, "meeting \(access)")
            let reminders = RemindersService(eventKit: false, defaults: defaults())
            reminders.setForTesting(access: access, items: [])
            let widget = RemindersWidget(reminders: reminders, calendar: CalendarService(eventKit: false))
            XCTAssertEqual(widget.needsSetup, expected, "reminders \(access)")
        }
    }

    func testNeedsSetupForAccessibilityFeatures() {
        XCTAssertTrue(HUDWidget.needsSetup(status: .needsAccessibility))
        for status: HUDWidget.Status in [.on, .stopped, .tapRefused] {
            XCTAssertFalse(HUDWidget.needsSetup(status: status), "\(status)")
        }
        XCTAssertTrue(WindowSnapWidget.needsSetup(status: .needsAccessibility))
        XCTAssertFalse(WindowSnapWidget.needsSetup(status: .on))
        XCTAssertFalse(WindowSnapWidget.needsSetup(status: .stopped))
        // The real widgets without Accessibility (trust: never) once running.
        let r = rig()
        r.registry.setEnabled(HUDWidget.widgetID, true)
        r.registry.setEnabled(WindowSnapWidget.widgetID, true)
        let hud = r.registry.widget(HUDWidget.widgetID) as! HUDWidget
        let snap = r.registry.widget(WindowSnapWidget.widgetID) as! WindowSnapWidget
        XCTAssertEqual(hud.status, .needsAccessibility)
        XCTAssertTrue(hud.needsSetup)
        XCTAssertEqual(snap.status, .needsAccessibility)
        XCTAssertTrue(snap.needsSetup)
        // Stopped (turned off) is not "needs setup".
        XCTAssertFalse(HUDWidget.inert().needsSetup)
        XCTAssertFalse(WindowSnapWidget.inert().needsSetup)
    }

    /// Mail: never allowed asks macOS ("Allow"), refused opens Settings, anything else needs nothing.
    func testMailSetup() {
        let table: [(MailWidget.Phase, MailWidget.SetupStep?)] = [
            (.needsAllow, .allow), (.denied(.never), .openSettings), (.denied(.otherBuild), .openSettings),
            (.notOpen, nil), (.off, nil), (.loading, nil), (.failed("x"), nil),
            (.inbox(MailInbox(unread: 0, latest: [])), nil),
        ]
        for (phase, step) in table {
            XCTAssertEqual(MailWidget.setupStep(phase: phase), step, "\(phase)")
        }
        let mail = MailWidget.inert()
        XCTAssertFalse(mail.needsSetup, "not running: nothing to set up")
        guard case .run = mail.setupAction else { return XCTFail("Mail's setup is its own action, not Settings") }
        mail.runSetup()   // in .off: does nothing, never a prompt
        XCTAssertEqual(mail.phase, .off)
    }

    /// Mirror: only a refusal (or a restriction) is setup; never asked is the tool's Show Mirror.
    func testMirrorSetup() {
        let table: [(MirrorTileState, Bool)] = [
            (.allow, false), (.ready, false), (.live, false), (.turnOnAgain, false), (.noCamera, false),
            (.denied(rebuilt: false), true), (.denied(rebuilt: true), true), (.restricted, true),
        ]
        for (state, expected) in table {
            XCTAssertEqual(MirrorWidget.needsSetup(state: state), expected, "\(state)")
        }
        let mirror = MirrorWidget.inert()
        XCTAssertEqual(mirror.tileState, .allow)
        XCTAssertFalse(mirror.needsSetup)
        guard case .run = mirror.setupAction else { return XCTFail("Mirror's setup opens Camera settings itself") }
    }

    /// Notes always works (quick notes go to "PlatyNotch notes"); Weather without a city does not.
    func testNotesAndWeatherSetup() {
        let notes = NotesWidget.inert()
        XCTAssertNil(notes.vault)
        XCTAssertFalse(notes.needsSetup)
        let weather = WeatherWidget.inert()
        XCTAssertTrue(weather.needsSetup)
    }

    /// Platy Chase's own entry opens the games on Chase.
    func testChaseEntrySelectsChase() throws {
        let r = rig()
        let games = try XCTUnwrap(r.registry.widget(GamesWidget.widgetID) as? GamesWidget)
        games.host.select(.snake)
        let chase = try XCTUnwrap(panel(r).panelTool(PanelTools.chase))
        XCTAssertEqual(chase.title, "Platy Chase")
        let host = NSHostingView(rootView: chase.view())
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: 528, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(games.host.session.kind, .chase)
    }

    /// Esc with a tool whose widget was turned off: the panel shows Home, so Esc closes it
    /// and the route is written back to Home.
    func testEscapeWithAToolThatIsGone() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.expand(tab: "music")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: "music"))
        r.registry.setEnabled("music", false)
        c.escapePressed()
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        XCTAssertNotEqual(c.mode, .expanded)
    }

    /// One tool by id resolves alone, and an unknown or turned-off one is nil.
    func testToolResolvesById() {
        let r = rig(extra: [])
        let p = panel(r, tabs: [pluginTab])
        XCTAssertEqual(p.panelTool("music")?.id, "music")
        XCTAssertEqual(p.panelTool(PanelTools.memory)?.title, "Memory")
        XCTAssertEqual(p.panelTool(PanelTools.plugin("fake.tab"))?.title, "Fake")
        XCTAssertNil(p.panelTool("nonsense"))
        r.registry.setEnabled("music", false)
        XCTAssertNil(p.panelTool("music"))
    }

    // MARK: Fix round 1: design polish

    /// "5 min ago", never "5 min, 0 secs".
    func testClipboardAgo() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ClipRow.ago(now.addingTimeInterval(-20), now: now), "Just now")
        XCTAssertEqual(ClipRow.ago(now.addingTimeInterval(-300), now: now), "5 min ago")
        XCTAssertEqual(ClipRow.ago(now.addingTimeInterval(-7_200), now: now), "2 hr ago")
        XCTAssertEqual(ClipRow.ago(now.addingTimeInterval(-86_400), now: now), "1 day ago")
        XCTAssertEqual(ClipRow.ago(now.addingTimeInterval(-3 * 86_400), now: now), "3 days ago")
        XCTAssertEqual(ClipRow.ago(now.addingTimeInterval(60), now: now), "Just now", "a clock skew never goes negative")
    }

    func testCommandDigitThreeIsUnused() {
        let r = rig()
        AgentsVisibility(forcedOn: true).save(to: defaults())
        r.today.agentActivity.loadVisibility(from: defaults())
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.expand()
        XCTAssertFalse(c.commandDigit(3))
        XCTAssertTrue(c.commandDigit(1))
        XCTAssertEqual(c.panelModel.route.destination, .home)
    }

    func testExpandLibraryTabOpensHome() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.expand(tab: "library")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
    }

    /// Every tool the Library held is reached by its old id: an open tool for each, never a
    /// dead end. This covers Clipboard, Sites & Shortcuts, Baskets and the Time tools.
    func testEveryOldLibraryToolIdOpensItsTool() {
        let r = rig()
        for w in r.registry.orderedWidgets { r.registry.setEnabled(w.id, true) }
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry,
                                extraTabs: [pluginTab])
        let p = panel(r, tabs: [pluginTab])
        let ids: Set<String> = ToolCatalog.ids(widgets: r.registry, extraTabs: [pluginTab])
        for id in [ClipboardWidget.widgetID, LaunchWidget.widgetID, BasketsWidget.widgetID, TimeWidget.widgetID,
                   PanelTools.memory, PanelTools.chase] {
            XCTAssertTrue(ids.contains(id), id)
            c.expand(tab: id)
            XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: id), id)
            XCTAssertNotNil(p.panelTool(id), "\(id) resolves to a view")
            c.escapePressed()
            XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home), id)
        }
        c.expand(tab: "fake.tab")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home, tool: "plugin:fake.tab"))
    }
}
