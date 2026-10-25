import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// XCTest brings in DeveloperToolsSupport, which has its own `LibraryItem` (Xcode's library).
private typealias LibraryItem = PlatyNotchKit.LibraryItem

/// A plugin-style widget that cannot work until set up (a dimmed "Set up" tile).
@MainActor
private final class EmptyToolWidget: NotchWidget {
    let id = "fake.empty"
    let title = "Empty"
    let systemImage = "questionmark.square"
    let defaultEnabled = true
    var setUps = 0
    var hasContent: Bool { false }
    var needsSetup: Bool { true }
    var setupAction: WidgetSetupAction { .run { [weak self] in self?.setUps += 1 } }
    func tileView() -> AnyView { AnyView(Text("tile")) }
}

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
    @Environment(\.inLibraryTool) private var inTool

    var body: some View {
        MainActor.assumeIsolated {
            record.tokens.insert(state.id)
            record.inTool.append(inTool)
        }
        return Color.clear.frame(height: height)
    }
}

/// A widget with nothing right now but nothing to set up: a normal tile.
@MainActor
private final class QuietToolWidget: NotchWidget {
    let id = "fake.quiet"
    let title = "Quiet"
    let systemImage = "moon.zzz"
    let defaultEnabled = true
    var hasContent: Bool { false }
    func tileView() -> AnyView { AnyView(Text("tile")) }
}

/// Task 21: the open panel has three destinations; today's tabs and plugin tabs are
/// Library tools that open full-panel (spec 6.1, 6.6, 6.9, 6.10).
@MainActor
final class LibraryViewTests: DefaultsTestCase {
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

    private func panel(_ r: Rig, tabs: [PanelTab] = [], route: PanelRoute = PanelRoute(destination: .library),
                       agentsVisible: Bool = true) -> ExpandedPanel {
        var current = route
        return ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                             today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                             extraTabs: tabs, route: Binding(get: { current }, set: { current = $0 }),
                             onCollapse: {}, glanceDefaults: defaults(), agentsVisible: agentsVisible,
                             onDecide: { _, _ in }, onOpenTerminal: { _ in })
    }

    private let pluginTab = PanelTab(id: "fake.tab", title: "Fake", systemImage: "puzzlepiece") { Text("plugin") }

    func testNavHasThreeDestinations() {
        XCTAssertEqual(ExpandedPanel.destinations(agentsVisible: true), [.now, .agents, .library])
        XCTAssertEqual(ExpandedPanel.destinations(agentsVisible: false), [.now, .library])
        let p = panel(rig(), tabs: [pluginTab])
        XCTAssertEqual(p.destinations, [.now, .agents, .library], "plugin tabs never add a destination")
    }

    /// Spec 6.10: Focus, Memory and Games (with Platy Chase beside it) and plugin tabs all
    /// live in the Library, in its input order.
    func testEveryOldTabHasAHome() {
        let ids = panel(rig(), tabs: [pluginTab]).libraryTools.map(\.item.id)
        for id in [FocusWidget.widgetID, LibraryTools.memory, GamesWidget.widgetID, LibraryTools.chase,
                   LibraryTools.plugin("fake.tab")] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let games = ids.firstIndex(of: GamesWidget.widgetID)!
        XCTAssertEqual(ids[games + 1], LibraryTools.chase, "Platy Chase right after Games")
        XCTAssertEqual(ids.suffix(2), [LibraryTools.memory, LibraryTools.plugin("fake.tab")], "then Memory, then plugins")
        // Every tool opens to a view.
        for tool in panel(rig(), tabs: [pluginTab]).libraryTools {
            let host = NSHostingView(rootView: tool.view().frame(width: 528, height: 280))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.width, 0, tool.item.id)
        }
    }

    /// `expand(tab:)` keeps its signature and maps through `PanelRoute.legacy`.
    func testLegacyExpandRoutes() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry,
                                extraTabs: [pluginTab])
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .now))
        c.expand(tab: "memory")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: LibraryTools.memory))
        c.expand(tab: BuiltinTab.today)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .now))
        c.expand(tab: BuiltinTab.games)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: GamesWidget.widgetID))
        c.expand(tab: "fake.tab")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: "plugin:fake.tab"))
        c.expand(tab: "music")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: "music"))
        c.expand(tab: BuiltinTab.agents)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .agents))
    }

    func testDimmedTileOffersSetUp() {
        let empty = EmptyToolWidget()
        let quiet = QuietToolWidget()
        let r = rig(extra: [empty, quiet])
        let quietItem = panel(r).libraryTools.first { $0.item.id == quiet.id }!.item
        XCTAssertTrue(quietItem.isSetUp, "nothing right now is not \"needs setup\"")
        XCTAssertEqual(LibraryTile.action(for: quietItem), .open)
        XCTAssertEqual(quietItem.liveLine, LibraryCatalog.fallbackLine)
        // Built-ins: no open loops is a calm line, not a dimmed tile; no city is setup.
        let loops = panel(r).libraryTools.first { $0.item.id == LoopsWidget.widgetID }!.item
        XCTAssertTrue(loops.isSetUp)
        XCTAssertEqual(loops.liveLine, "No open loops")
        let weather = panel(r).libraryTools.first { $0.item.id == WeatherWidget.widgetID }
        if let weather { XCTAssertFalse(weather.item.isSetUp, "no city chosen") }
        let p = panel(r)
        let tool = p.libraryTools.first { $0.item.id == empty.id }
        XCTAssertEqual(tool?.item.isSetUp, false)
        XCTAssertEqual(LibraryTile.action(for: tool!.item), .setUp)
        let music = p.libraryTools.first { $0.item.id == "music" }!
        XCTAssertEqual(LibraryTile.action(for: music.item), .open)
        // "Set up" runs the widget's own setup (else its settings page).
        var opened: [String] = []
        var setUp: [String] = []
        let view = LibraryView(items: [tool!.item, music.item], tile: { _ in nil },
                               onOpen: { opened.append($0) }, onSetUp: { setUp.append($0) })
        view.activate(tool!.item)
        view.activate(music.item)
        XCTAssertEqual(setUp, [empty.id])
        XCTAssertEqual(opened, ["music"])
        p.setUp(empty.id)
        XCTAssertEqual(empty.setUps, 1)
        // The dimmed tile names its one action for VoiceOver.
        XCTAssertEqual(LibraryTile.accessibilityHint(for: tool!.item), "Set up Empty")
    }

    func testGridIsFourColumns() {
        XCTAssertEqual(LibraryView.columnCount, 4)
        XCTAssertEqual(LibraryView.tileWidth, (528 - 3 * LibraryView.spacing) / 4)
        let items = (0..<12).map { LibraryItem(id: "t\($0)", title: "Tool \($0) with a very long name indeed",
                                               systemImage: "star", liveLine: String(repeating: "live ", count: 30),
                                               isSetUp: $0 % 3 != 0) }
        let host = NSHostingView(rootView: LibraryView(items: items, tile: { _ in nil }, onOpen: { _ in },
                                                       onSetUp: { _ in }).frame(width: 528, height: 288))
        host.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.fittingSize.width, 528)
        // Twelve tools fit three rows without scrolling.
        XCTAssertLessThanOrEqual(LibraryView.gridHeight(count: 12), 288)
        XCTAssertFalse(LibraryView.scrolls(count: 12, height: 288))
        XCTAssertTrue(LibraryView.scrolls(count: 13, height: 288))
        let tile = NSHostingView(rootView: LibraryTile(item: items[1], custom: nil, onTap: {}).fixedSize())
        tile.layoutSubtreeIfNeeded()
        XCTAssertEqual(tile.fittingSize.width, LibraryView.tileWidth, accuracy: 0.5)
        XCTAssertEqual(tile.fittingSize.height, LibraryView.tileHeight, accuracy: 0.5, "long text never grows a tile")
    }

    func testDisabledWidgetsNotListed() {
        let r = rig()
        XCTAssertTrue(panel(r).libraryTools.contains { $0.item.id == "music" })
        r.registry.setEnabled("music", false)
        XCTAssertFalse(panel(r).libraryTools.contains { $0.item.id == "music" })
        r.registry.setEnabled(GamesWidget.widgetID, false)
        let ids = panel(r).libraryTools.map(\.item.id)
        XCTAssertFalse(ids.contains(GamesWidget.widgetID))
        XCTAssertFalse(ids.contains(LibraryTools.chase), "Platy Chase goes with Games")
        XCTAssertTrue(ids.contains(LibraryTools.memory))
    }

    /// Opening a tool notes it, so the grid puts it first next time; back returns to the grid.
    func testOpeningAToolPutsItFirst() {
        let r = rig()
        var route = PanelRoute(destination: .library)
        let p = ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                              today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                              extraTabs: [], route: Binding(get: { route }, set: { route = $0 }),
                              onCollapse: {}, glanceDefaults: defaults(), onDecide: { _, _ in }, onOpenTerminal: { _ in })
        p.openTool(LibraryTools.memory)
        XCTAssertEqual(route, PanelRoute(destination: .library, tool: LibraryTools.memory))
        XCTAssertEqual(p.sortedLibraryItems().first?.id, LibraryTools.memory)
        p.goBack()
        XCTAssertEqual(route, PanelRoute(destination: .library))
    }

    /// Glances and the quiet line open their tool directly (through Now's `onOpenTool`).
    func testGlanceLinksOpenTheirTool() {
        XCTAssertEqual(ExpandedPanel.route(forTool: "loops"), PanelRoute(destination: .library, tool: "loops"))
        let r = rig()
        var route = PanelRoute(destination: .now)
        let p = ExpandedPanel(store: r.store, responder: ApprovalResponder(client: r.client), arming: ApprovalArming(),
                              today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                              extraTabs: [], route: Binding(get: { route }, set: { route = $0 }),
                              onCollapse: {}, glanceDefaults: defaults(), onDecide: { _, _ in }, onOpenTerminal: { _ in })
        p.nowView.onOpenTool(LoopsWidget.widgetID)
        XCTAssertEqual(route, PanelRoute(destination: .library, tool: LoopsWidget.widgetID))
        p.nowView.onOpenTool(FocusWidget.widgetID)
        XCTAssertEqual(route, PanelRoute(destination: .library, tool: FocusWidget.widgetID))
        XCTAssertEqual(LibraryRecents.load(from: defaults()).lastOpened(FocusWidget.widgetID) != nil, true,
                       "a glance counts as using the tool")
    }

    /// The tool header: back chevron with its VoiceOver name, and the tool's title.
    func testToolHostHasABackChevron() {
        var backs = 0
        let host = ToolHost(title: "Memory", onBack: { backs += 1 }, content: AnyView(Text("x")))
        XCTAssertEqual(ToolHost.backLabel, "Back to Library")
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

    /// Every tile has one calm line that fits it (the coordinator's grid review).
    func testEveryTileHasALine() {
        let r = rig()
        for w in r.registry.orderedWidgets { r.registry.setEnabled(w.id, true) }
        let font = NSFont.systemFont(ofSize: TypeScale.caption.size, weight: .medium)
        let room: CGFloat = LibraryView.tileWidth - 2 * Space.m
        let titleFont = NSFont.systemFont(ofSize: TypeScale.body.size, weight: .semibold)
        for tool in panel(r, tabs: [pluginTab]).libraryTools {
            let line = tool.item.liveLine ?? ""
            XCTAssertFalse(line.trimmingCharacters(in: .whitespaces).isEmpty, tool.item.id)
            let width = (line as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, room, "\(tool.item.id): \"\(line)\" truncates")
            let titleWidth = (tool.item.title as NSString).size(withAttributes: [.font: titleFont]).width
            XCTAssertLessThanOrEqual(titleWidth, room, "\(tool.item.id): \"\(tool.item.title)\" truncates")
        }
        // Only real setup dims a tile: weather without a city does; empty shelf, clipboard and
        // loops do not.
        let items = Dictionary(uniqueKeysWithValues: panel(r).libraryTools.map { ($0.item.id, $0.item) })
        XCTAssertEqual(items[WeatherWidget.widgetID]?.isSetUp, false)
        for id in [ShelfWidget.widgetID, ClipboardWidget.widgetID, LoopsWidget.widgetID, TimeWidget.widgetID,
                   MusicWidget.widgetID] {
            XCTAssertEqual(items[id]?.isSetUp, true, id)
        }
        XCTAssertEqual(items[MusicWidget.widgetID]?.liveLine, "Nothing playing")
        XCTAssertEqual(items[ShelfWidget.widgetID]?.liveLine, "Empty")
    }

    /// ⌘1…⌘3 only, never Return or a digit alone.
    func testCommandDigits() throws {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags, code: UInt16 = 18) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        XCTAssertEqual(NotchPanel.commandDigit(try key("1", .command)), 1)
        XCTAssertEqual(NotchPanel.commandDigit(try key("2", .command)), 2)
        XCTAssertEqual(NotchPanel.commandDigit(try key("3", .command)), 3)
        XCTAssertNil(NotchPanel.commandDigit(try key("4", .command)))
        XCTAssertNil(NotchPanel.commandDigit(try key("1", [])), "a digit alone types")
        XCTAssertNil(NotchPanel.commandDigit(try key("1", [.command, .shift])))
        XCTAssertNil(NotchPanel.commandDigit(try key("\r", .command, code: 36)), "never Return")
        XCTAssertNil(NotchPanel.commandDigit(try key("\r", [], code: 36)))
    }

    /// ⌘1 / ⌘2 / ⌘3 switch destinations in the open panel, also from inside a tool.
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
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .now))
        XCTAssertTrue(c.commandDigit(3))
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library))
        XCTAssertFalse(c.commandDigit(4))
        // Agents hidden: ⌘2 does nothing.
        let hidden = rig()
        let h = NotchController(store: hidden.store, client: hidden.client, plugins: [], today: hidden.today,
                                widgets: hidden.registry)
        h.expand()
        XCTAssertFalse(h.commandDigit(2))
        XCTAssertEqual(h.panelModel.route, PanelRoute(destination: .now))
    }

    /// Esc goes back from a tool to the Library first, then closes the panel.
    func testEscapeGoesBackBeforeClosing() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.expand(tab: "memory")
        XCTAssertEqual(c.mode, .expanded)
        c.escapePressed()
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library))
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
            XCTAssertEqual(LibraryCatalog.item(for: meeting).isSetUp, !expected, "meeting tile \(access)")
            let reminders = RemindersService(eventKit: false, defaults: defaults())
            reminders.setForTesting(access: access, items: [])
            let widget = RemindersWidget(reminders: reminders, calendar: CalendarService(eventKit: false))
            XCTAssertEqual(widget.needsSetup, expected, "reminders \(access)")
            XCTAssertEqual(LibraryCatalog.item(for: widget).isSetUp, !expected, "reminders tile \(access)")
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
        let items = Dictionary(uniqueKeysWithValues: panel(r).libraryTools.map { ($0.item.id, $0.item) })
        XCTAssertEqual(items[HUDWidget.widgetID]?.isSetUp, false)
        XCTAssertEqual(items[WindowSnapWidget.widgetID]?.isSetUp, false)
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
        XCTAssertNil(mail.setupTitle)
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
        XCTAssertEqual(LibraryCatalog.item(for: mirror).liveLine, "Click to show")
        guard case .run = mirror.setupAction else { return XCTFail("Mirror's setup opens Camera settings itself") }
    }

    /// Notes always works (quick notes go to "PlatyNotch notes"); Weather without a city does not.
    func testNotesAndWeatherSetup() {
        let notes = NotesWidget.inert()
        XCTAssertNil(notes.vault)
        XCTAssertFalse(notes.needsSetup)
        XCTAssertEqual(LibraryCatalog.item(for: notes).liveLine, "Quick notes")
        let weather = WeatherWidget.inert()
        XCTAssertTrue(weather.needsSetup)
        XCTAssertEqual(LibraryCatalog.item(for: weather).isSetUp, false)
    }

    /// Platy Chase's own entry opens the games on Chase.
    func testChaseEntrySelectsChase() throws {
        let r = rig()
        let games = try XCTUnwrap(r.registry.widget(GamesWidget.widgetID) as? GamesWidget)
        games.host.select(.snake)
        let chase = try XCTUnwrap(panel(r).libraryTool(LibraryTools.chase))
        XCTAssertEqual(chase.item.title, "Platy Chase")
        let host = NSHostingView(rootView: chase.view())
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: 528, height: 300),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(games.host.session.kind, .chase)
    }

    /// Esc with a tool whose widget was turned off: the panel shows the grid, so Esc closes it
    /// and the route is written back to the grid.
    func testEscapeWithAToolThatIsGone() {
        let r = rig()
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.expand(tab: "music")
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library, tool: "music"))
        r.registry.setEnabled("music", false)
        c.escapePressed()
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .library))
        XCTAssertNotEqual(c.mode, .expanded)
    }

    /// One tool by id resolves alone, and an unknown or turned-off one is nil.
    func testToolResolvesById() {
        let r = rig(extra: [])
        let p = panel(r, tabs: [pluginTab])
        XCTAssertEqual(p.libraryTool("music")?.item.id, "music")
        XCTAssertEqual(p.libraryTool(LibraryTools.memory)?.item.title, "Memory")
        XCTAssertEqual(p.libraryTool(LibraryTools.plugin("fake.tab"))?.item.title, "Fake")
        XCTAssertNil(p.libraryTool("nonsense"))
        r.registry.setEnabled("music", false)
        XCTAssertNil(p.libraryTool("music"))
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

    /// A running timer marks its tile live (the teal dot); nothing running is not live.
    func testLiveToolsAreMarked() throws {
        let r = rig()
        let time = try XCTUnwrap(r.registry.widget(TimeWidget.widgetID) as? TimeWidget)
        XCTAssertFalse(LibraryCatalog.item(for: time).isLive)
        XCTAssertEqual(LibraryCatalog.item(for: time).liveLine, "No timers")
        XCTAssertTrue(time.addTimer("25m"))
        XCTAssertTrue(LibraryCatalog.item(for: time).isLive)
        XCTAssertEqual(LibraryCatalog.item(for: time).liveLine, "1 timer")
    }
}
