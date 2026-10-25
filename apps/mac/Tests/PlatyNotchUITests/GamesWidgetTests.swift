import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// The games controller against the real pause signals: approvals in an `AppStore`, rings
/// in `PanelSurfaces`, a panel tab's state. No window, no frames from a display.
@MainActor
final class GamesWidgetTests: DefaultsTestCase {



    @MainActor private struct Rig {
        let store: AppStore
        let surfaces: PanelSurfaces
        let widget: GamesWidget
        let defaults: UserDefaults
        let tab = UUID()
        var host: GameHost { widget.host }
    }

    private func rig() -> Rig {
        let store = AppStore()
        store.apply(.connected)
        let surfaces = PanelSurfaces()   // no registry: every ring is accepted
        let d = defaults()
        let w = GamesWidget(defaults: d)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pngames\(UUID().uuidString)")
        w.start(context: WidgetContext(store: store, client: CoreClient(socketPath: "/nonexistent"),
                                       config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                       events: CoreEventHub(), defaults: d, notify: NoopNotifier(),
                                       surfaces: surfaces, openPanel: { _ in }))
        return Rig(store: store, surfaces: surfaces, widget: w, defaults: d)
    }

    /// The tab is on screen in an open panel and the board was clicked; Space starts `kind`.
    private func play(_ r: Rig, _ kind: GameKind = .snake) {
        r.host.select(kind)
        r.host.surfaceChanged(r.tab, GameSurface(shown: true, fullScreen: false, focused: true))
        XCTAssertTrue(r.host.handle(.space, from: r.tab))
        XCTAssertEqual(r.host.session.phase, .playing)
    }

    private func addApproval(_ r: Rig, id: String = "ap1") throws {
        let a = Approval(id: id, sessionKey: "s1", agent: "claude-code", agentName: "Claude Code", tool: "Bash",
                         summary: "ls", createdAt: Date(), expiresAt: Date().addingTimeInterval(300))
        r.store.apply(try Envelope.make(.approvalAdded, a))
    }

    private func resolveApproval(_ r: Rig, id: String = "ap1") throws {
        r.store.apply(try Envelope.make(.approvalResolved, ApprovalResolved(id: id, behavior: "allow", source: "notch")))
    }

    /// Lets the observation hop (`Task { @MainActor … }`) run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    func testDoesNoWorkUntilOpened() {
        let r = rig()
        XCTAssertFalse(r.host.isRunning)
        XCTAssertEqual(r.host.session.phase, .ready)
        XCTAssertTrue(r.host.blockers.collapsed, "no tab on screen yet")
        let before = r.host.session
        r.host.frame(now: 1, from: r.tab)
        r.host.frame(now: 2, from: r.tab)
        XCTAssertFalse(r.host.handle(.space, from: UUID()), "no tab was clicked: keys are not the game's")
        XCTAssertEqual(r.host.session, before, "frames and keys before play change nothing")
        XCTAssertNil(r.defaults.data(forKey: HighScores.key), "nothing saved")
    }

    func testApprovalMidGamePausesAndKeysDoNotReachTheGame() async throws {
        let r = rig()
        play(r)
        r.host.frame(now: 10, from: r.tab)
        r.host.frame(now: 10 + GameSession.snakeStep + 0.001, from: r.tab)
        let snapshot = r.host.session.snake

        try addApproval(r)
        await settle()
        XCTAssertEqual(r.host.session.phase, .paused, "paused by the store change alone, no frame needed")
        XCTAssertTrue(r.host.blockers.approval)
        XCTAssertTrue(r.host.approvalPending)
        XCTAssertFalse(r.host.isRunning, "the frame loop stops")

        for k in [GameKey.up, .down, .left, .right, .space, .escape] {
            XCTAssertFalse(r.host.handle(k, from: r.tab), "\(k) is not the game's while an approval is pending")
        }
        r.host.frame(now: 11, from: r.tab)
        r.host.frame(now: 12, from: r.tab)
        XCTAssertEqual(r.host.session.snake, snapshot)
    }

    func testKeysNeverReachTheGameEvenBeforeTheObservationFires() throws {
        let r = rig()
        play(r)
        r.host.frame(now: 0, from: r.tab)
        try addApproval(r)
        // No yield: the key itself re-reads the store.
        XCTAssertFalse(r.host.handle(.left, from: r.tab))
        XCTAssertEqual(r.host.session.phase, .paused)
    }

    func testResumeAfterApprovalRestoresExactState() async throws {
        let r = rig()
        play(r, .tetris)
        r.host.frame(now: 0, from: r.tab)
        r.host.frame(now: 0.25, from: r.tab)
        XCTAssertTrue(r.host.handle(.left, from: r.tab))
        XCTAssertTrue(r.host.handle(.up, from: r.tab))
        let snapshot = r.host.session.tetris

        try addApproval(r)
        await settle()
        XCTAssertEqual(r.host.session.phase, .paused)
        // The approval took the tab's room: the board (and its key view) went away.
        r.host.surfaceChanged(r.tab, GameSurface(shown: true, fullScreen: false, focused: false))
        try resolveApproval(r)
        await settle()
        XCTAssertEqual(r.host.session.phase, .paused, "never resumes by itself")
        XCTAssertFalse(r.host.handle(.space, from: UUID()), "not from a tab nobody clicked")

        r.host.surfaceChanged(r.tab, GameSurface(shown: true, fullScreen: false, focused: true))   // click
        XCTAssertTrue(r.host.handle(.space, from: r.tab))
        XCTAssertEqual(r.host.session.phase, .playing)
        XCTAssertEqual(r.host.session.tetris, snapshot, "exactly where it left off")
        r.host.frame(now: 500, from: r.tab)   // first frame after the resume only sets the clock
        XCTAssertEqual(r.host.session.tetris, snapshot)
    }

    func testRingingPausesTheGame() async {
        let r = rig()
        play(r, .flappy)
        r.host.frame(now: 0, from: r.tab)
        r.host.frame(now: 0.05, from: r.tab)
        let bird = r.host.session.flappy
        XCTAssertTrue(r.surfaces.ring(id: "time.alarm", title: "Alarm"))
        await settle()
        XCTAssertEqual(r.host.session.phase, .paused)
        XCTAssertTrue(r.host.blockers.ringing)
        XCTAssertTrue(r.host.handle(.space, from: r.tab), "Space is taken (not passed to the panel)")
        XCTAssertEqual(r.host.session.phase, .paused, "but cannot resume while it rings")
        r.host.frame(now: 1, from: r.tab)
        XCTAssertEqual(r.host.session.flappy, bird)

        r.surfaces.stopRinging(id: "time.alarm")
        await settle()
        XCTAssertTrue(r.host.handle(.space, from: r.tab))
        XCTAssertEqual(r.host.session.phase, .playing)
        XCTAssertEqual(r.host.session.flappy, bird)
    }

    func testCollapseKeyLossAndFullScreenPause() {
        let surfaces: [GameSurface] = [
            GameSurface(shown: false, fullScreen: false, focused: true),   // collapsed / hidden
            GameSurface(shown: true, fullScreen: false, focused: false),   // panel resigned key
            GameSurface(shown: true, fullScreen: true, focused: true),     // full screen
        ]
        for s in surfaces {
            let r = rig()
            play(r)
            r.host.surfaceChanged(r.tab, s)
            XCTAssertEqual(r.host.session.phase, .paused, "\(s)")
            XCTAssertFalse(r.host.isRunning)
        }
        let r = rig()
        play(r)
        r.host.surfaceGone(r.tab)   // the tab left (panel collapsed, other tab)
        XCTAssertEqual(r.host.session.phase, .paused)
    }

    func testEscapePausesThenGoesToThePanel() {
        let r = rig()
        play(r)
        XCTAssertTrue(r.host.handle(.escape, from: r.tab))
        XCTAssertEqual(r.host.session.phase, .paused)
        XCTAssertFalse(r.host.handle(.escape, from: r.tab), "the next Escape closes the panel")
    }

    func testNewBestCelebratesAndIsSaved() {
        let r = rig()
        var told: [GameResult] = []
        r.widget.onNewBest = { told.append($0) }
        play(r)
        var s = r.host.session
        s.snake.food = PlatyNotchKit.Point(x: s.snake.body[0].x + 1, y: s.snake.body[0].y)
        // Drive the engine through the host: frames until the snake hits the wall.
        r.host.session = s
        var t = 0.0
        r.host.frame(now: t, from: r.tab)
        t += GameSession.snakeStep + 0.0001
        r.host.frame(now: t, from: r.tab)
        var tweak = r.host.session
        tweak.snake.food = PlatyNotchKit.Point(x: 0, y: 0)
        r.host.session = tweak
        while r.host.session.phase == .playing, t < 30 {
            t += GameSession.snakeStep
            r.host.frame(now: t, from: r.tab)
        }
        XCTAssertEqual(r.host.session.phase, .over)
        XCTAssertEqual(told, [GameResult(kind: .snake, score: 1)])
        XCTAssertEqual(r.widget.celebration?.result, GameResult(kind: .snake, score: 1))
        XCTAssertEqual(HighScores.load(from: r.defaults).best("snake"), 1, "UserDefaults (the test suite here)")
        XCTAssertEqual(GamesWidget(defaults: r.defaults).host.session.best, 1, "read back on the next launch")
    }

    func testStopPausesAndForgetsTheSignals() async throws {
        let r = rig()
        play(r)
        r.widget.stop()
        XCTAssertEqual(r.host.session.phase, .paused)
        try addApproval(r)
        await settle()
        XCTAssertFalse(r.host.approvalPending, "a stopped widget reads nothing")
    }

    func testInertNeverSaves() {
        let saved = UserDefaults.standard.data(forKey: HighScores.key)
        let w = GamesWidget.inert()
        XCTAssertEqual(w.host.session.scores, HighScores(), "reads nothing either")
        var s = w.host.session
        s.scores.record(game: "snake", score: 3)
        w.host.session = s
        w.host.resetScores()
        XCTAssertEqual(UserDefaults.standard.data(forKey: HighScores.key), saved)
    }

    /// Approval shortcuts (⌘↩, ⌘⌫) and other chords never become game keys.
    func testCommandChordsAreNotGameKeys() throws {
        func event(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        }
        XCTAssertNil(GameKey(event: try event("\r", 36, .command)))
        XCTAssertNil(GameKey(event: try event("\u{7f}", 51, .command)))
        XCTAssertNil(GameKey(event: try event(" ", 49, .command)))
        XCTAssertNil(GameKey(event: try event("a", 0, .control)))
        XCTAssertEqual(GameKey(event: try event(" ", 49, [])), .space)
        XCTAssertEqual(GameKey(event: try event("w", 13, [])), .up)
        XCTAssertEqual(GameKey(event: try event("\u{F702}", 123, [.function, .numericPad])), .left)
    }

    /// The board takes first responder only after a click: never by itself (hover, the
    /// panel becoming key).
    func testKeyViewTakesFocusOnlyAfterAClick() {
        let v = GameKeyView()
        XCTAssertFalse(v.acceptsFirstResponder)
        var focus: [Bool] = []
        v.onFocus = { focus.append($0) }
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        v.mouseDown(with: click!)
        XCTAssertTrue(v.acceptsFirstResponder)
        XCTAssertFalse(v.hasFocus, "no window: not focused")
        _ = v.resignFirstResponder()
        XCTAssertFalse(v.acceptsFirstResponder)
    }

    /// Two displays showing the Games tab both run a TimelineView: only the owner's frames
    /// advance the game, so it never runs at double speed.
    func testFramesOnlyFromTheOwner() {
        let r = rig()
        play(r)
        let other = UUID()
        r.host.surfaceChanged(other, GameSurface(shown: true, fullScreen: false, focused: false))
        XCTAssertEqual(r.host.owner, r.tab)
        let head = r.host.session.snake.body[0]
        r.host.frame(now: 0, from: r.tab)
        r.host.frame(now: 0, from: other)
        r.host.frame(now: GameSession.snakeStep + 0.001, from: other)   // ignored
        XCTAssertEqual(r.host.session.snake.body[0], head)
        r.host.frame(now: GameSession.snakeStep + 0.001, from: r.tab)
        XCTAssertEqual(r.host.session.snake.body[0].x, head.x + 1, "one step, from the owner's clock only")
    }

    /// Key loss disarms the board: the panel becoming key again (hover, a click elsewhere
    /// on it) does not give the board keys until it is clicked itself.
    func testKeyLossDisarmsTheBoard() {
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: 100, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let v = GameKeyView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView = v
        var focus: [Bool] = []
        v.onFocus = { focus.append($0) }
        v.mouseDown(with: click())
        XCTAssertTrue(v.armed)
        XCTAssertTrue(window.firstResponder === v)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(v.armed)
        XCTAssertFalse(v.acceptsFirstResponder)
        XCTAssertFalse(window.firstResponder === v, "gave up first responder")
        XCTAssertEqual(focus.last, false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertFalse(v.hasFocus, "becoming key again is not a click on the board")
        _ = window.makeFirstResponder(v)
        XCTAssertFalse(window.firstResponder === v, "only a click arms it")
    }

    func testRepeatsAreMarked() throws {
        let held = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: " ",
                                                  charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        XCTAssertEqual(GameKey(event: held), GameKey(.space, isRepeat: true))
    }

    private func click() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testGamesTabFitsTheExpandedPanel() {
        XCTAssertNil(AppDelegate.checkGameViews())
    }
}
