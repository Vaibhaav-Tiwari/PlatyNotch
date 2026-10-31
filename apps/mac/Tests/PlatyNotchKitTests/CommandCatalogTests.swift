import Foundation
import XCTest
@testable import PlatyNotchKit

/// User feedback: nothing showed off the features. With the command line focused and empty,
/// everything Platy can do is listed, grouped Do / Open / Toggle; typing filters it.
final class CommandCatalogTests: DefaultsTestCase {
    private let everything: Set<String> = ["clipboard", "shelf", "baskets", "mirror", "memory", "launch", "games"]

    func testGroupsAndOrder() {
        let entries = CommandCatalog.entries(tools: everything, shortcuts: [:])
        XCTAssertEqual(entries.filter { $0.group == .do }.map(\.title), ["Timer", "Focus", "Remind", "Note"])
        XCTAssertEqual(entries.filter { $0.group == .open }.map(\.title),
                       ["Clipboard", "Shelf", "Baskets", "Mirror", "Memory", "Sites & Shortcuts", "Games"])
        XCTAssertEqual(entries.filter { $0.group == .toggle }.map(\.title), ["Keep awake"])
        XCTAssertEqual(CommandCatalog.Group.allCases.map(\.title), ["Do", "Open", "Toggle"])
        XCTAssertEqual(entries.first?.hint, "timer 10m")
        XCTAssertEqual(entries.first?.action, .fill("timer "))
        XCTAssertEqual(entries.first { $0.title == "Shelf" }?.action, .open(tool: "shelf"))
        XCTAssertEqual(entries.last?.action, .toggleKeepAwake)
        XCTAssertTrue(entries.allSatisfy { !$0.symbol.isEmpty && !$0.hint.isEmpty })
    }

    func testUnavailableToolsAreLeftOut() {
        let entries = CommandCatalog.entries(tools: ["memory"], shortcuts: [:])
        XCTAssertEqual(entries.filter { $0.group == .open }.map(\.title), ["Mirror", "Memory"],
                       "Mirror turns its widget on when opened; the rest need theirs on")
    }

    func testShortcutsShowWhereTheyExist() {
        let entries = CommandCatalog.entries(tools: everything, shortcuts: ["clipboard": "⌥⇧V"])
        XCTAssertEqual(entries.first { $0.title == "Clipboard" }?.shortcut, "⌥⇧V")
        XCTAssertNil(entries.first { $0.title == "Shelf" }?.shortcut)
    }

    func testTypingFilters() {
        let entries = CommandCatalog.entries(tools: everything, shortcuts: [:])
        XCTAssertEqual(CommandCatalog.filter(entries, query: "cl").map(\.title), ["Clipboard"])
        XCTAssertEqual(CommandCatalog.filter(entries, query: "  SH ").map(\.title), ["Shelf", "Sites & Shortcuts"],
                       "case-insensitive, title words or hint")
        XCTAssertEqual(CommandCatalog.filter(entries, query: "").count, entries.count)
        XCTAssertEqual(CommandCatalog.filter(entries, query: "zzz"), [])
    }

    func testAliasesAndFuzzyMatch() {
        let entries = CommandCatalog.entries(tools: everything.union(["notes", "time"]), shortcuts: [:])
        XCTAssertTrue(entries.allSatisfy { !$0.aliases.isEmpty }, "every entry has aliases")
        func titles(_ q: String) -> [String] { CommandCatalog.filter(entries, query: q).map(\.title) }
        XCTAssertEqual(titles("games"), ["Games"])
        XCTAssertEqual(titles("game"), ["Games"])
        XCTAssertEqual(titles("play"), ["Games"])
        XCTAssertEqual(titles("notes"), ["Notes", "Note"], "an exact name ranks first")
        XCTAssertEqual(titles("note"), ["Note", "Notes"])
        XCTAssertEqual(titles("clip"), ["Clipboard"])
        XCTAssertEqual(titles("mem"), ["Memory"])
        XCTAssertEqual(titles("timer"), ["Timer"])
        XCTAssertEqual(titles("time"), ["Time", "Timer"])
        XCTAssertEqual(titles("gms"), ["Games"], "fuzzy: letters in order")
        XCTAssertEqual(titles("xyzzy"), [])
        XCTAssertEqual(titles("remind call mom at 5pm"), [])
    }

    /// The upgrade hint shows on the first three opens, then never again.
    func testHintOnFirstThreeOpens() {
        let d = defaults()
        XCTAssertTrue(CommandCatalog.showsHint(d))
        for _ in 0..<3 { CommandCatalog.notePanelOpened(d) }
        XCTAssertFalse(CommandCatalog.showsHint(d))
        CommandCatalog.notePanelOpened(d)
        XCTAssertEqual(d.integer(forKey: CommandCatalog.hintCountKey), 3, "stops counting")
    }
}
