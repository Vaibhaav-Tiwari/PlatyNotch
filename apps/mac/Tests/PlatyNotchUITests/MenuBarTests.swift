import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class MenuBarTests: XCTestCase {
    /// Without this, AppKit re-enables every item with a target and `isEnabled` is ignored.
    func testMenuDoesNotAutoenable() {
        XCTAssertFalse(MenuBarController.newMenu().autoenablesItems)
    }

    func testPauseItemDisabledWhenCaptureCannotRun() {
        XCTAssertEqual(MenuBarController.pauseItemState(.off).enabled, false)
        XCTAssertEqual(MenuBarController.pauseItemState(.needsAccessibility).enabled, false)
        XCTAssertEqual(MenuBarController.pauseItemState(.off).title, "Pause capture for 1 hour")
    }

    func testPauseItemEnabledWhileCapturingOrPaused() {
        XCTAssertEqual(MenuBarController.pauseItemState(.capturing).enabled, true)
        XCTAssertEqual(MenuBarController.pauseItemState(.capturing).title, "Pause capture for 1 hour")
        let paused = MenuBarController.pauseItemState(.paused(until: Date(timeIntervalSince1970: 0)))
        XCTAssertTrue(paused.enabled)
        XCTAssertTrue(paused.title.hasPrefix("Resume capture (paused until "), paused.title)
    }

    func testUpdatesItemFollowsSparkleWhenUpdatesAreOn() {
        XCTAssertEqual(MenuBarController.updatesItemState(isEnabled: true, canCheck: true).enabled, true)
        XCTAssertEqual(MenuBarController.updatesItemState(isEnabled: true, canCheck: false).enabled, false)
        XCTAssertEqual(MenuBarController.updatesItemState(isEnabled: true, canCheck: false).title, "Check for Updates…")
    }

    func testUpdatesItemOpensReleasesPageWhenUpdatesAreOff() {
        // No Sparkle key: the item links to GitHub Releases and is always available.
        let s = MenuBarController.updatesItemState(isEnabled: false, canCheck: false)
        XCTAssertEqual(s.title, "Download Updates from GitHub Releases…")
        XCTAssertTrue(s.enabled)
    }

    /// C23: "Pause clipboard history" exists only while the widget runs, and flips to Resume.
    func testClipboardItemFollowsTheWidget() {
        XCTAssertTrue(MenuBarController.clipboardItemState(running: false, paused: false).hidden)
        XCTAssertTrue(MenuBarController.clipboardItemState(running: false, paused: true).hidden)
        let on = MenuBarController.clipboardItemState(running: true, paused: false)
        XCTAssertEqual(on.title, "Pause clipboard history")
        XCTAssertFalse(on.hidden)
        XCTAssertEqual(MenuBarController.clipboardItemState(running: true, paused: true).title, "Resume clipboard history")
    }

    /// The clipboard item is added through the same non-autoenabling menu (C23).
    func testClipboardItemKeepsAutoenableOff() {
        let menu = MenuBarController.newMenu()
        let item = NSMenuItem(title: "Pause clipboard history", action: #selector(NSObject.description), keyEquivalent: "")
        item.target = NSObject()
        item.isEnabled = false
        menu.addItem(item)
        menu.update()
        XCTAssertFalse(menu.autoenablesItems)
        XCTAssertFalse(item.isEnabled, "isEnabled is ours, not AppKit's")
    }

    /// C36: the menu bar icon is Platy's template silhouette (macOS tints it), 18 pt, and
    /// actually draws something (opaque pixels, eyes cut out).
    func testIconIsPlatyTemplate() throws {
        for dot in [false, true] {
            let image = MenuBarController.icon(dot: dot)
            XCTAssertTrue(image.isTemplate)
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
            let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            var opaque = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
            }
            let total = rep.pixelsWide * rep.pixelsHigh
            XCTAssertGreaterThan(opaque, total / 5, "a solid silhouette")
            XCTAssertLessThan(opaque, total * 3 / 4, "with room around it")
        }
    }

    func testGamesItemListsEveryGame() {
        XCTAssertEqual(MenuBarController.gameTitles, ["Snake", "Tetris", "2048", "Flappy", "Platy Chase"])
    }

    func testGamesItemHiddenWhileGamesOff() {
        XCTAssertTrue(MenuBarController.gamesItemHidden(gamesOn: false))
        XCTAssertFalse(MenuBarController.gamesItemHidden(gamesOn: true))
    }

    func testChoosingAGameOpensIt() {
        var opened: [GameKind] = []
        let games = GamesWidget.inert()
        XCTAssertTrue(MenuBarController.chooseGame(titled: "Platy Chase", games: games, open: { opened.append($0) }))
        XCTAssertEqual(opened, [.chase])
        XCTAssertEqual(games.host.session.kind, .chase, "picked in the games tool")
        XCTAssertTrue(MenuBarController.chooseGame(titled: "2048", games: games, open: { opened.append($0) }))
        XCTAssertEqual(opened, [.chase, .twenty48])
        XCTAssertFalse(MenuBarController.chooseGame(titled: "Pong", games: games, open: { opened.append($0) }))
        XCTAssertEqual(opened.count, 2)
    }

    /// Every tool the Library held stays reachable from the menu bar, but the games, which
    /// have their own item.
    func testOpenSubmenuListsTheToolsButNotTheGames() {
        let tools: [CommandTool] = [CommandTool(id: "clipboard", title: "Clipboard"),
                                    CommandTool(id: GamesWidget.widgetID, title: "Games"),
                                    CommandTool(id: PanelTools.chase, title: "Platy Chase"),
                                    CommandTool(id: "baskets", title: "Baskets"),
                                    CommandTool(id: PanelTools.memory, title: "Memory")]
        XCTAssertEqual(MenuBarController.openItems(tools).map(\.title), ["Clipboard", "Baskets", "Memory"])
    }
}
