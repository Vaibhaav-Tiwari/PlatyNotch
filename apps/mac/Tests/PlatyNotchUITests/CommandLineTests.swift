import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class CommandLineTests: DefaultsTestCase {
    /// Records what the command line asked for.
    private final class Spy {
        var timers: [(TimeInterval, String?)] = []
        var focus: [Int] = []
        var reminded: [QuickAdd] = []
        var notes: [String] = []
        var searches: [String] = []
        var routes: [PanelRoute] = []
        var games: [GameKind] = []
        var remindReply: String?
        var noteReply: String?

        var actions: CommandActions {
            var a = CommandActions()
            a.startTimer = { [self] d, l in timers.append((d, l)); return true }
            a.startFocus = { [self] in focus.append($0) }
            a.remind = { [self] in reminded.append($0); return remindReply }
            a.note = { [self] in notes.append($0); return noteReply }
            a.search = { [self] in searches.append($0) }
            a.open = { [self] in routes.append($0) }
            a.selectGame = { [self] in games.append($0) }
            return a
        }
    }

    private func logic(_ spy: Spy, model: PanelViewModel = PanelViewModel(), approvals: Bool = false,
                       tools: [CommandTool] = []) -> (CommandLineLogic, PanelViewModel) {
        let l = CommandLineLogic(model: model, runner: CommandRunner(actions: spy.actions), tools: { tools },
                                 approvalsPending: { approvals }, clock: { Date(timeIntervalSince1970: 1_793_448_000) },
                                 calendar: Calendar(identifier: .gregorian))
        return (l, model)
    }

    private func controller() -> (NotchController, WidgetRegistry, HomeRenders.Rig) {
        let r = HomeRenders.builtIns(meeting: false)
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.panelIsKey = { true }
        return (c, r.registry, r)
    }

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags = [], code: UInt16 = 40) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, characters: chars,
                                       charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    func testCommandKFocusesCommandLine() {
        let (c, _, rig) = controller()
        XCTAssertFalse(c.commandK(), "compact: not used")
        c.expand()
        XCTAssertEqual(c.mode, .expanded)
        XCTAssertTrue(c.commandK())
        XCTAssertTrue(c.panelModel.commandFocused)
        c.panelIsKey = { false }
        c.panelModel.commandFocused = false
        XCTAssertFalse(c.commandK(), "only while the panel has the keyboard")
        XCTAssertFalse(c.panelModel.commandFocused)
        rig.registry.stopAll()
    }

    func testCommandKFromAnotherViewGoesHome() {
        let (c, _, rig) = controller()
        c.expand(tab: "memory")
        XCTAssertNotNil(c.panelModel.route.tool)
        XCTAssertTrue(c.commandK())
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        rig.registry.stopAll()
    }

    func testCommandKKeyEvent() throws {
        XCTAssertTrue(NotchPanel.isCommandK(try key("k", .command, code: 40)))
        XCTAssertTrue(NotchPanel.isCommandK(try key("K", .command, code: 40)))
        XCTAssertFalse(NotchPanel.isCommandK(try key("k", [], code: 40)))
        XCTAssertFalse(NotchPanel.isCommandK(try key("k", [.command, .shift], code: 40)))
        XCTAssertFalse(NotchPanel.isCommandK(try key("\r", .command, code: 36)), "⌘↩ is the approval's")
    }

    func testTypingStartsCommandLine() throws {
        let (c, _, rig) = controller()
        c.expand()
        XCTAssertTrue(c.typed("t"))
        XCTAssertEqual(c.panelModel.commandText, "t")
        XCTAssertTrue(c.panelModel.commandFocused)
        XCTAssertTrue(c.typed("i"))
        XCTAssertEqual(c.panelModel.commandText, "ti")
        // A field that has focus keeps its keys; ⌘ and ⌃ are never typing.
        c.textFieldFocused = { true }
        XCTAssertFalse(c.typed("x"))
        c.textFieldFocused = { false }
        XCTAssertNil(NotchPanel.typedText(try key("t", .command)))
        XCTAssertNil(NotchPanel.typedText(try key("t", .control)))
        XCTAssertEqual(NotchPanel.typedText(try key("t")), "t")
        XCTAssertEqual(NotchPanel.typedText(try key("T", .shift)), "T")
        XCTAssertNil(NotchPanel.typedText(try key("\r", code: 36)))
        XCTAssertNil(NotchPanel.typedText(try key("\u{F700}", code: 126)), "arrows are not text")
        XCTAssertNil(NotchPanel.typedText(try key("\u{7F}", code: 51)), "delete is not text")
        c.panelIsKey = { false }
        XCTAssertFalse(c.typed("z"))
        rig.registry.stopAll()
    }

    func testTypingInAToolIsLeftToTheTool() {
        let (c, _, rig) = controller()
        c.expand(tab: GamesWidget.widgetID)
        XCTAssertFalse(c.typed("a"), "a game keeps its keys")
        XCTAssertEqual(c.panelModel.commandText, "")
        rig.registry.stopAll()
    }

    func testReturnRunsTopSuggestion() {
        let spy = Spy()
        let (l, model) = logic(spy)
        model.commandText = "timer 10m tea"
        XCTAssertNil(l.submit())
        XCTAssertEqual(spy.timers.count, 1)
        XCTAssertEqual(spy.timers.first?.0, 600)
        XCTAssertEqual(spy.timers.first?.1, "tea")
        XCTAssertEqual(model.commandText, "", "cleared once it ran")
    }

    func testNothingRunsWithoutReturn() {
        let spy = Spy()
        let (l, model) = logic(spy)
        model.commandText = "focus"
        _ = l.suggestions
        model.commandText = "focus 50"
        _ = l.suggestions
        XCTAssertEqual(spy.focus, [])
        XCTAssertNil(spy.timers.first)
        l.submit()
        XCTAssertEqual(spy.focus, [50])
    }

    func testArrowsMoveTheChosenRow() {
        let spy = Spy()
        let (l, model) = logic(spy, tools: [CommandTool(id: "clipboard", title: "Clipboard")])
        model.commandText = "cli"
        XCTAssertEqual(l.suggestions.count, 3)
        XCTAssertEqual(l.selectedIndex, 0)
        l.move(by: 1)
        XCTAssertEqual(l.selectedIndex, 1)
        l.move(by: -2)
        XCTAssertEqual(l.selectedIndex, 2, "wraps")
        l.submit()
        XCTAssertEqual(spy.routes, [PanelRoute(destination: .home, tool: "clipboard")])
    }

    func testRemindPassesQuickAdd() {
        let spy = Spy()
        let (l, model) = logic(spy)
        model.commandText = "remind call Priya at 5pm"
        l.submit()
        XCTAssertEqual(spy.reminded.first?.title, "Call Priya")
        XCTAssertEqual(spy.reminded.first?.hasTime, true)
    }

    func testBlockedCommandSaysWhyAndKeepsText() {
        let spy = Spy()
        spy.remindReply = "Allow Reminders in Settings"
        let (l, model) = logic(spy)
        model.commandText = "remind call Priya at 5pm"
        XCTAssertEqual(l.submit(), "Allow Reminders in Settings")
        XCTAssertEqual(model.commandMessage, "Allow Reminders in Settings")
        XCTAssertEqual(model.commandText, "remind call Priya at 5pm", "nothing is lost")
    }

    func testExplanationRowNeverRuns() {
        let spy = Spy()
        let (l, model) = logic(spy)
        model.commandText = "timer 25h"
        let message = l.submit()
        XCTAssertNotNil(message)
        XCTAssertEqual(spy.timers.count, 0)
        XCTAssertEqual(model.commandText, "timer 25h")
    }

    func testNoteWhenNotesOffSaysWhy() {
        let r = HomeRenders.builtIns(meeting: false)
        r.registry.setEnabled(NotesWidget.widgetID, false)
        let root = PanelRootView(model: PanelViewModel(), store: r.store, responder: ApprovalResponder(client: r.client),
                                 today: r.today, widgets: r.registry, memory: MemoryServices(client: r.client),
                                 extraTabs: [], onOpenTerminal: { _ in })
        XCTAssertEqual(root.commandActions.note("buy milk"), "Turn on Notes in Settings")
        r.registry.setEnabled(RemindersWidget.widgetID, false)
        XCTAssertEqual(root.commandActions.remind(QuickAddParser.parse("x", now: Date(), calendar: .current)),
                       "Turn on Reminders in Settings")
        r.registry.stopAll()
    }

    func testRemindWithoutAccessSaysWhy() {
        let r = HomeRenders.builtIns(meeting: false)
        (r.registry.widget(RemindersWidget.widgetID) as? RemindersWidget)?.reminders.setForTesting(access: .denied, items: [])
        let widget = r.registry.widget(RemindersWidget.widgetID) as? RemindersWidget
        let q = QuickAddParser.parse("call Priya", now: Date(), calendar: .current)
        XCTAssertEqual(widget?.add(q), "Allow Reminders in Settings")
        r.registry.stopAll()
    }

    func testPlayChaseOpensChase() {
        let spy = Spy()
        let (l, model) = logic(spy)
        model.commandText = "play chase"
        l.submit()
        XCTAssertEqual(spy.routes, [PanelRoute(destination: .home, tool: PanelTools.chase)])
        model.commandText = "play snake"
        l.submit()
        XCTAssertEqual(spy.routes.last, PanelRoute(destination: .home, tool: GamesWidget.widgetID))
        XCTAssertEqual(spy.games, [.chase, .snake])
        model.commandText = "play"
        l.submit()
        XCTAssertEqual(spy.routes.last, PanelRoute(destination: .home, tool: GamesWidget.widgetID))
    }

    func testSearchOpensMemoryWithTheQuery() {
        let spy = Spy()
        let (l, model) = logic(spy)
        model.commandText = "search budget"
        l.submit()
        XCTAssertEqual(spy.searches, ["budget"])
        XCTAssertEqual(spy.routes, [PanelRoute(destination: .home, tool: PanelTools.memory)])
    }

    func testEscClearsThenLeaves() {
        let (c, _, rig) = controller()
        c.expand()
        XCTAssertTrue(c.typed("t"))
        c.escapePressed()
        XCTAssertEqual(c.panelModel.commandText, "")
        XCTAssertTrue(c.panelModel.commandFocused)
        XCTAssertEqual(c.mode, .expanded)
        c.escapePressed()
        XCTAssertFalse(c.panelModel.commandFocused)
        XCTAssertEqual(c.mode, .expanded, "the panel stays open")
        c.escapePressed()
        XCTAssertNotEqual(c.mode, .expanded, "then Esc closes it")
        rig.registry.stopAll()
    }

    func testClosingThePanelForgetsTheCommand() {
        let (c, _, rig) = controller()
        c.expand()
        c.typed("t")
        c.collapse()
        XCTAssertEqual(c.panelModel.commandText, "")
        XCTAssertFalse(c.panelModel.commandFocused)
        rig.registry.stopAll()
    }

    /// Review focus: an approval arrives while the command line has text. Return never runs the
    /// command or answers the approval (the approval's own ⌘↩ / ⌘⌫ do, as today).
    func testCommandLineNeverAnswersApprovals() {
        let spy = Spy()
        let (l, model) = logic(spy, approvals: true)
        model.commandText = "timer 5m"
        XCTAssertEqual(l.submit(), CommandLineLogic.approvalMessage)
        XCTAssertEqual(spy.timers.count, 0, "the typed command does not run")
        XCTAssertEqual(model.commandText, "timer 5m")
        XCTAssertFalse(NotchPanel.isCommandK(try! key("\r", .command, code: 36)), "⌘↩ is not a command-line key")
    }

    func testApprovalKeysStayOnTheCard() throws {
        // ⌘↩ / ⌘⌫ are the card buttons' shortcuts; the command line adds no Return handler to the
        // card and the panel's key handling never takes them.
        let panel = NotchPanel(frame: CGRect(x: -10_000, y: 10_000, width: 10, height: 10))
        var used: [String] = []
        panel.onTyped = { used.append($0); return true }
        panel.onCommandK = { used.append("K"); return true }
        XCTAssertNil(NotchPanel.typedText(try key("\r", .command, code: 36)))
        XCTAssertNil(NotchPanel.typedText(try key("\u{7F}", .command, code: 51)))
        XCTAssertEqual(used, [])
    }
}
