import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The in-panel tools (Island spec 4): Note, Remind, Clipboard.
@MainActor
final class ToolViewsTests: DefaultsTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_450_000)

    // MARK: - Note

    func testNoteReturnAppendsAndClears() async {
        let notes = NotesWidget.inert()
        var appended: [String] = []
        let pad = NotePad(notes: notes, append: { appended.append($0); return nil })
        pad.text = "buy milk"
        XCTAssertTrue(pad.submit())
        XCTAssertEqual(appended, ["buy milk"])
        XCTAssertEqual(pad.text, "", "cleared")
        XCTAssertTrue(pad.keepsFocus, "the pad stays focused for the next note")
        pad.text = "   "
        XCTAssertFalse(pad.submit(), "nothing to add")
        XCTAssertEqual(appended.count, 1)
    }

    /// An approval arrives while the pad has "abc": Return appends (never answers it), and
    /// ⌘↩ / ⌘⌫ belong to the focused field, not to the approval's buttons.
    func testNotePadNeverAnswersApprovals() throws {
        var appended: [String] = []
        let pad = NotePad(notes: NotesWidget.inert(), append: { appended.append($0); return nil })
        pad.text = "abc"
        XCTAssertTrue(pad.submit())
        XCTAssertEqual(appended, ["abc"])
        func key(_ code: UInt16, _ c: String) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: c, charactersIgnoringModifiers: c,
                                           isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(NotchPanel.keyBelongsToText(try key(36, "\r"), textFocused: true))
        XCTAssertTrue(NotchPanel.keyBelongsToText(try key(51, "\u{8}"), textFocused: true))
    }

    func testNoteEmptyState() {
        XCTAssertTrue(NoteTool.texts(entries: []).contains("Nothing noted today. Type above and press Return."))
        XCTAssertEqual(NoteTool.texts(entries: ["c", "b"]), ["c", "b"])
    }

    // MARK: - Remind

    func testRemindListsOverdueFirst() {
        let items = [ReminderItem(id: "t", title: "Today", due: now.addingTimeInterval(3600), hasTime: true),
                     ReminderItem(id: "o", title: "Late", due: now.addingTimeInterval(-86_400 * 2), hasTime: false)]
        let texts = RemindTool.texts(items, access: .granted, now: now, calendar: .current)
        XCTAssertEqual(texts.first, "Overdue")
        XCTAssertEqual(texts.dropFirst().first, "Late")
    }

    func testRemindNoAccessAsksOnlyOnClick() {
        let service = RemindersService(eventKit: false)
        service.setForTesting(access: .notAsked, items: [])
        var asked = 0
        let tool = RemindTool(reminders: service, onAdd: { _ in nil }, onAllow: { asked += 1 })
        let host = NSHostingView(rootView: tool.environment(\.colorScheme, .dark))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(asked, 0, "building the view asks nothing")
        XCTAssertTrue(RemindTool.texts([], access: .notAsked, now: now, calendar: .current).contains("Allow Reminders"))
    }

    // MARK: - Clipboard

    func testClipboardSearchFilters() {
        let items = [ClipItem(kind: .text("hello world"), copiedAt: now),
                     ClipItem(kind: .url(URL(string: "https://example.com/a")!), copiedAt: now),
                     ClipItem(kind: .text("token sk-abcdefghijklmnopqrstuvwxyz123456"), copiedAt: now)]
        XCTAssertEqual(ClipboardTool.filtered(items, query: "url").count, 1)
        XCTAssertEqual(ClipboardTool.filtered(items, query: "example").count, 1)
        XCTAssertEqual(ClipboardTool.filtered(items, query: "").count, 3)
        XCTAssertEqual(ClipboardTool.displayText(items[2]), ClipboardTool.maskedText)
        XCTAssertEqual(ClipboardTool.displayText(items[0]), "hello world")
    }

    func testToolRowsUseNeutralWells() {
        XCTAssertEqual(ToolRow<EmptyView>.wellColor, DS.raised)
        XCTAssertEqual(ToolRow<EmptyView>.wellSize, 28)
    }

    // MARK: - Shelf, Memory, Games

    func testShelfRowsNameAndSize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pnshelf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let report = dir.appendingPathComponent("report.pdf"), photo = dir.appendingPathComponent("photo.png")
        try Data(count: 1_200_000).write(to: report)
        try Data(count: 340_000).write(to: photo)
        let items = [ShelfItem(kind: .file(ShelfFileRef(path: report.path)), addedAt: now),
                     ShelfItem(kind: .file(ShelfFileRef(path: photo.path)), addedAt: now)]
        let rows = ShelfTool.rows(items)
        XCTAssertEqual(rows.map(\.title), ["report.pdf", "photo.png"])
        XCTAssertEqual(rows.map(\.detail), ["1.2 MB", "340 KB"])
        let text = ShelfTool.rows([ShelfItem(kind: .text("Release checklist"), addedAt: now)])
        XCTAssertEqual(text.first?.title, "Release checklist")
        XCTAssertEqual(text.first?.detail, "Text")
    }

    func testShelfEmptyIsADropBox() {
        XCTAssertEqual(ShelfTool.texts([]), ["Drop files here to keep them"])
        XCTAssertTrue(ShelfTool.showsPlatyWhenEmpty)
    }

    func testShelfToolHasNoGrid() throws {
        XCTAssertFalse(ShelfTool.usesGrid)
        let source = try String(contentsOf: DesignLintTests.uiSources.appendingPathComponent("Tools/ShelfTool.swift"),
                                encoding: .utf8)
        XCTAssertFalse(source.contains("LazyVGrid"))
        let tile = try String(contentsOf: DesignLintTests.uiSources.appendingPathComponent("Shelf/Views/ShelfTile.swift"),
                              encoding: .utf8)
        XCTAssertFalse(tile.contains("LazyVGrid"), "the tool's grid branch is gone")
    }

    func testAirDropAllInHeader() {
        let one = [ShelfItem(kind: .text("x"), addedAt: now)]
        XCTAssertEqual(ShelfTool.accessoryTitle(canAirDrop: true, items: one), "AirDrop all")
        XCTAssertNil(ShelfTool.accessoryTitle(canAirDrop: false, items: one))
        XCTAssertNil(ShelfTool.accessoryTitle(canAirDrop: true, items: []))
    }

    func testMemoryShowsLoopsOrEmpty() {
        let loops = [Loop(id: "1", title: "Send Priya the deck", kind: "promise", status: "open", detectedAt: now),
                     Loop(id: "2", title: "Review the PR", kind: "follow-up", status: "open", detectedAt: now)]
        XCTAssertEqual(MemoryTool.texts(loops), ["Send Priya the deck", "Review the PR"])
        XCTAssertEqual(MemoryTool.texts([]), ["No open loops. Platy's keeping watch."])
    }

    func testGamesRowsEveryKind() {
        let scores = HighScores(scores: [GameKind.chase.rawValue: 4120])
        let rows = GamesTool.rows(scores, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(rows.map(\.title), GameKind.allCases.map(\.title))
        XCTAssertTrue(rows.last?.detail.hasSuffix("best 4,120") ?? false, rows.last?.detail ?? "")
        XCTAssertFalse(rows.first?.detail.contains("best") ?? true, "no best at 0")
    }

    func testGameRowOpensGame() {
        let model = GamesToolModel()
        XCTAssertNil(model.picked)
        model.open(.snake)
        XCTAssertEqual(model.picked, .snake)
        model.back()
        XCTAssertNil(model.picked)
    }
}
