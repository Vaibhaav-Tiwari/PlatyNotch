import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// User feedback round: the global command shortcut, the first click in the command line,
/// and the list of everything the command line can do.
@MainActor
final class CommandDiscoveryTests: DefaultsTestCase {
    private func controller() -> (NotchController, HomeRenders.Rig) {
        let r = HomeRenders.builtIns(meeting: false)
        let c = NotchController(store: r.store, client: r.client, plugins: [], today: r.today, widgets: r.registry)
        c.debugHandle(.layout(HomeRenders.layout))
        return (c, r)
    }

    // MARK: - ⌥⌘K

    func testHotKeyOpensHomeWithTheCommandLineFocused() {
        let (c, r) = controller()
        c.panelModel.route = PanelRoute(destination: .agents)
        XCTAssertTrue(c.commandHotKey())
        XCTAssertEqual(c.panelModel.mode, .expanded)
        XCTAssertEqual(c.panelModel.route, PanelRoute(destination: .home))
        XCTAssertTrue(c.panelModel.commandFocused)
        XCTAssertTrue(c.panelModel.commandActive, "the list shows")
        XCTAssertEqual(c.keyRequests, 1, "the panel takes the keyboard on purpose")
        r.registry.stopAll()
    }

    func testHotKeyAgainWhileFocusedCloses() {
        let (c, r) = controller()
        c.panelIsKey = { true }
        c.commandHotKey()
        c.panelModel.commandText = "tim"
        XCTAssertFalse(c.commandHotKey())
        XCTAssertNotEqual(c.panelModel.mode, .expanded)
        XCTAssertEqual(c.panelModel.commandText, "", "a closed panel keeps no half-typed command")
        r.registry.stopAll()
    }

    /// Hover never takes the keyboard: only the shortcut and a click do.
    func testHoverOpenNeverTakesTheKeyboard() {
        let (c, r) = controller()
        c.hoverSample(inside: true, at: 100)
        c.hoverSample(inside: true, at: 101)
        XCTAssertEqual(c.panelModel.mode, .expanded)
        XCTAssertEqual(c.keyRequests, 0)
        XCTAssertFalse(c.panelModel.commandFocused)
        r.registry.stopAll()
    }

    /// The first click in the command line field gives the panel the keyboard and focuses it.
    func testFirstClickRequestsTheKeyboard() {
        let panel = NotchPanel(frame: CGRect(x: -10_000, y: 10_000, width: 100, height: 40))
        XCTAssertFalse(panel.canBecomeKey)
        panel.grantKey()
        XCTAssertFalse(panel.canBecomeKey, "never in a mode that may not take the keyboard")
        panel.allowsKey = true
        panel.grantKey()
        XCTAssertTrue(panel.canBecomeKey)
        let model = PanelViewModel()
        var asked = 0
        model.requestKey = { asked += 1 }
        CommandLineView.fieldClicked(model)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(model.commandFocused)
        XCTAssertTrue(model.commandActive)
    }

    // MARK: - The list

    private func logic(_ model: PanelViewModel, opened: @escaping (String) -> Void = { _ in },
                       keepAwake: @escaping () -> Void = {}) -> CommandLineLogic {
        var a = CommandActions()
        a.openTool = opened
        a.toggleKeepAwake = keepAwake
        let catalog = CommandCatalog.entries(tools: ["clipboard", "shelf", "memory"], shortcuts: ["clipboard": "⌥⇧V"])
        return CommandLineLogic(model: model, runner: CommandRunner(actions: a),
                                tools: { [CommandTool(id: "clipboard", title: "Clipboard")] },
                                catalog: { catalog }, clock: { Date(timeIntervalSince1970: 1_793_448_000) },
                                calendar: Calendar(identifier: .gregorian))
    }

    func testFocusedAndEmptyListsEverything() {
        let model = PanelViewModel()
        let l = logic(model)
        XCTAssertTrue(l.rows.isEmpty, "not asked for: nothing")
        model.commandFocused = true
        XCTAssertTrue(l.rows.isEmpty, "a field that merely took focus lists nothing")
        model.commandActive = true
        XCTAssertEqual(l.rows.compactMap(\.entry).map(\.title),
                       ["Timer", "Focus", "Remind", "Note", "Clipboard", "Shelf", "Mirror", "Memory", "Keep awake"])
    }

    func testArrowsAndReturnRunARow() {
        let model = PanelViewModel()
        var opened: [String] = []
        var awake = 0
        let l = logic(model, opened: { opened.append($0) }, keepAwake: { awake += 1 })
        model.commandActive = true
        l.move(by: -1)   // wraps to the last row: Keep awake
        l.submit()
        XCTAssertEqual(awake, 1)
        XCTAssertFalse(model.commandActive, "done: Home comes back")
        model.commandActive = true
        model.commandSelection = 0
        l.submit()   // Timer fills the field, ready for its argument
        XCTAssertEqual(model.commandText, "timer ")
        XCTAssertTrue(model.commandActive, "still typing")
        model.commandText = ""
        model.commandSelection = 4   // Clipboard
        l.submit()
        XCTAssertEqual(opened, ["clipboard"])
    }

    func testTypingFiltersAndNeverDuplicates() {
        let model = PanelViewModel()
        let l = logic(model)
        model.commandActive = true
        model.commandText = "sh"
        XCTAssertEqual(l.rows.compactMap(\.entry).map(\.title), ["Shelf"])
        model.commandText = "clip"
        let titles = l.rows.map(\.title)
        XCTAssertEqual(titles.filter { $0.contains("Clipboard") }.count, 1, "\(titles)")
    }
}

/// The global shortcut's registration and routing (no real shortcut is ever grabbed).
@MainActor
final class CommandHotKeyControllerTests: XCTestCase {
    @MainActor private final class FakeRegistration: HotKeyRegistration {
        var unregistered = false
        func unregister() { unregistered = true }
    }

    @MainActor private final class Maker {
        var made: [(UInt32, UInt32)] = []
        var handlers: [@MainActor () -> Void] = []
        var registrations: [FakeRegistration] = []
        var refuse = false
        var make: HotKeyMaker {
            { [self] code, mods, handler in
                guard !refuse else { return nil }
                made.append((code, mods))
                handlers.append(handler)
                let r = FakeRegistration()
                registrations.append(r)
                return r
            }
        }
    }

    func testRegistersAndRoutesThePress() {
        let maker = Maker()
        let c = CommandHotKeyController(catalog: SharedHotKeyCatalog(), makeHotKey: maker.make)
        var pressed = 0
        c.onPress = { pressed += 1 }
        c.apply(CommandHotKey.presets[0])
        XCTAssertTrue(c.holds)
        XCTAssertEqual(maker.made.first?.0, 40)
        XCTAssertEqual(maker.made.first?.1, KeyCombo.option | KeyCombo.command)
        maker.handlers.first?()
        XCTAssertEqual(pressed, 1)
        c.apply(CommandHotKey.presets[0])
        XCTAssertEqual(maker.made.count, 1, "unchanged: not registered twice")
        c.apply(nil)
        XCTAssertFalse(c.holds)
        XCTAssertTrue(maker.registrations[0].unregistered, "turned off: released")
    }

    func testConflictsAreNamed() {
        let catalog = SharedHotKeyCatalog()
        catalog.claim(CommandHotKey.presets[1], for: BasketSettings.switcherFeature)
        let maker = Maker()
        let c = CommandHotKeyController(catalog: catalog, makeHotKey: maker.make)
        c.apply(CommandHotKey.presets[1])
        XCTAssertTrue(c.taken)
        XCTAssertEqual(c.usedBy, "Baskets")
        XCTAssertTrue(maker.made.isEmpty, "never registered over another feature")
        XCTAssertEqual(c.takenNote, "⌃⌥⌘K is used by Baskets in PlatyNotch.")
        maker.refuse = true
        c.apply(CommandHotKey.presets[0])
        XCTAssertTrue(c.taken)
        XCTAssertNil(c.usedBy)
        XCTAssertEqual(c.takenNote, "⌥⌘K is taken by another app. Pick another.")
        XCTAssertNil(catalog.catalog.combo(for: CommandHotKey.feature), "a refused shortcut is not kept in the catalog")
    }
}
