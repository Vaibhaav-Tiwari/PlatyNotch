import AppKit
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class PlipPlayerTests: DefaultsTestCase {
    private var played: [(URL, Float)] = []
    private var front: String? = "com.apple.Safari"
    private var clock = Date(timeIntervalSince1970: 5_000_000)
    /// A fresh folder for this test's files, removed afterwards.
    private lazy var tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-plip-\(getpid())-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }()

    private func player() -> PlipPlayer {
        PlipPlayer(defaults: defaults(), seams: PlipPlayer.Seams(
            frontmost: { [unowned self] in self.front },
            isRunning: { _ in false },
            play: { [unowned self] url, volume in self.played.append((url, volume)); return true },
            now: { [unowned self] in self.clock }))
    }

    private func session(term: String?) -> Session {
        Session(key: "s", agent: "codex", agentName: "Codex", sessionID: "s", state: .waitingInput,
                termProgram: term, startedAt: clock, updatedAt: clock)
    }

    private func enable() {
        var s = PlipSettings.load(from: defaults())
        s.enabled = true
        s.save(to: defaults())
    }

    /// A mono 16-bit WAV of `seconds` of quiet tone.
    private func wav(_ name: String, seconds: Double) throws -> URL {
        let rate = 8000, n = Int(Double(rate) * seconds)
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(n * 2))
        for i in 0..<n { u16(UInt16(bitPattern: Int16(sin(Double(i) * 0.3) * 2000))) }
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testOffByDefault() {
        let p = player()
        p.agentNeedsYou(session(term: "iTerm.app"))
        XCTAssertTrue(played.isEmpty)
    }

    func testPlaysChatterAtAModerateVolume() throws {
        enable()
        let p = player()
        p.agentNeedsYou(session(term: "iTerm.app"))
        let first = try XCTUnwrap(played.first)
        XCTAssertEqual(first.0, CueSound.plip.url)
        XCTAssertEqual(first.1, PlipPolicy.volume)
    }

    func testMutedWhenTheAgentsTerminalIsFrontmost() {
        enable()
        front = TerminalApps.iTermID
        let p = player()
        p.agentNeedsYou(session(term: "iTerm.app"))
        XCTAssertTrue(played.isEmpty)
        front = "com.apple.Safari"
        p.agentNeedsYou(session(term: "iTerm.app"))
        XCTAssertEqual(played.count, 1)
    }

    /// Several sessions or an approval and its session at once: one sound.
    func testOneSoundForABurst() {
        enable()
        let p = player()
        p.agentNeedsYou(session(term: nil))
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.count, 1)
        clock = clock.addingTimeInterval(PlipPlayer.quietGap + 0.1)
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.count, 2)
    }

    func testChosenFileIsKeptAsABookmark() throws {
        let file = try wav("bell.wav", seconds: 0.5)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .ok)
        let saved = PlipSettings.load(from: defaults())
        XCTAssertEqual(saved.choice, .custom)
        XCTAssertEqual(saved.customName, "bell.wav")
        XCTAssertNotNil(saved.bookmark)
        // The bookmark leads back to the user's own file (nothing is copied).
        XCTAssertEqual(PlipPlayer.resolve(saved)?.standardizedFileURL.resolvingSymlinksInPath(),
                       file.standardizedFileURL.resolvingSymlinksInPath())
        enable()
        let p = player()
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.first?.0.lastPathComponent, "bell.wav")
    }

    func testRejectsALongFile() throws {
        let file = try wav("long.wav", seconds: 6)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        guard case .tooLong = model.choose(file) else { return XCTFail("a 6 s file was accepted") }
        XCTAssertNotNil(model.error)
        XCTAssertEqual(PlipSettings.load(from: defaults()).choice, .chatter)
    }

    func testRejectsAFileThatDoesNotPlay() throws {
        let file = tempDir.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: file)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .unreadable)
        XCTAssertNil(PlipSettings.load(from: defaults()).bookmark)
    }

    /// A chosen file that has gone away falls back to Platy chatter.
    func testMissingFileFallsBackToChatter() throws {
        let file = try wav("gone.wav", seconds: 0.3)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .ok)
        try FileManager.default.removeItem(at: file)
        enable()
        let p = player()
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.first?.0, CueSound.plip.url)
    }

    func testPreviewPlaysEvenWhenOff() {
        var previews = 0
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in previews += 1; return true })
        model.preview()
        XCTAssertEqual(previews, 1)
    }

    func testBundledChatterIsShort() throws {
        let url = try XCTUnwrap(CueSound.plip.url)
        let duration = try XCTUnwrap(PlipPlayer.duration(of: url))
        XCTAssertLessThanOrEqual(duration, 0.6)
    }

    // MARK: Wiring (fix round 1)

    private func waiting(_ key: String, term: String? = nil, state: SessionState = .waitingInput) -> Session {
        Session(key: key, agent: "claude-code", agentName: "Claude Code", sessionID: key, state: state,
                termProgram: term, startedAt: clock, updatedAt: clock)
    }

    private func approval(_ id: String, session: String) -> Approval {
        Approval(id: id, sessionKey: session, agent: "claude-code", agentName: "Claude Code", project: "p",
                 tool: "Bash", summary: "ls", createdAt: clock, expiresAt: clock.addingTimeInterval(300))
    }

    /// Through the app's one tracker: a session entering "needs you" makes one sound.
    func testFollowPlaysOncePerNeedsYou() {
        enable()
        let activity = AgentActivityModel()
        let store = AppStore()
        let p = player()
        p.follow(activity, store: store)
        activity.sessionsChanged([waiting("a", state: .active)], now: clock)
        XCTAssertTrue(played.isEmpty)
        activity.sessionsChanged([waiting("a")], now: clock)
        XCTAssertEqual(played.count, 1)
        // Still waiting: no new change, no new sound.
        clock = clock.addingTimeInterval(10)
        activity.sessionsChanged([waiting("a")], now: clock)
        XCTAssertEqual(played.count, 1)
    }

    /// Each new approval sounds once; approvals already there when the app starts do not.
    func testFollowPlaysOncePerNewApproval() async throws {
        enable()
        let activity = AgentActivityModel()
        let store = AppStore()
        store.apply(.connected)
        store.apply(try Envelope.make(.approvalAdded, approval("old", session: "s")))
        let p = player()
        p.follow(activity, store: store)
        await drainMainQueue()
        XCTAssertTrue(played.isEmpty, "an approval already waiting makes no sound")
        store.apply(try Envelope.make(.approvalAdded, approval("new", session: "s")))
        let heard = await eventually { self.played.count == 1 }
        XCTAssertTrue(heard)
        clock = clock.addingTimeInterval(PlipPlayer.quietGap + 1)
        store.apply(try Envelope.make(.approvalAdded, approval("third", session: "s")))
        let again = await eventually { self.played.count == 2 }
        XCTAssertTrue(again)
    }

    /// Several sessions enter at once: it plays unless every one of them is muted.
    func testPlaysUnlessEveryEnteringSessionIsMuted() {
        enable()
        front = TerminalApps.iTermID
        let p = player()
        p.agentNeedsYou([waiting("a", term: "iTerm.app"), waiting("b", term: "iTerm.app")])
        XCTAssertTrue(played.isEmpty)
        p.agentNeedsYou([waiting("a", term: "iTerm.app"), waiting("b", term: "Apple_Terminal")])
        XCTAssertEqual(played.count, 1)
    }

    /// "Agent needs you" set to quiet in focus sessions: no sound while one runs.
    /// Approvals' row is locked to never quiet: they still sound.
    func testFocusRowsAreHonoured() {
        enable()
        var policy = NotificationPolicy.load(from: defaults())
        var rule = policy[.agentNeedsYou]
        rule.quietDuringFocus = true
        policy[.agentNeedsYou] = rule
        policy.save(to: defaults())
        let p = player()
        p.focusActive = { true }
        p.agentNeedsYou(session(term: nil))
        XCTAssertTrue(played.isEmpty)
        p.approvalArrived(session(term: nil))
        XCTAssertEqual(played.count, 1)
        // Out of focus, needs-you sounds again.
        clock = clock.addingTimeInterval(PlipPlayer.quietGap + 1)
        p.focusActive = { false }
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.count, 2)
    }

    /// By default (the row is not quiet in focus) needs-you sounds during a focus session.
    func testNeedsYouSoundsInFocusByDefault() {
        enable()
        let p = player()
        p.focusActive = { true }
        p.agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.count, 1)
    }

    /// A chosen file replaced by a long one falls back to Platy chatter.
    func testReplacedLongFileFallsBackToChatter() throws {
        let file = try wav("swap.wav", seconds: 0.4)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .ok)
        let long = try wav("long-swap.wav", seconds: 6)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: long)
        XCTAssertEqual(PlipPlayer.url(for: PlipSettings.load(from: defaults())), CueSound.plip.url)
    }

    /// A new best while an approval waits: no celebration.
    func testNewBestDuringApprovalDoesNotCelebrate() throws {
        let registry = WidgetRegistry(defaults: defaults())
        let today = TodayServices(client: CoreClient(socketPath: "/nonexistent"))
        let store = AppStore()
        store.apply(.connected)
        store.apply(try Envelope.make(.approvalAdded, approval("a", session: "s")))
        BuiltInWidgets.register(in: registry, store: store, today: today, persist: false)
        let games = try XCTUnwrap(registry.widget(GamesWidget.widgetID) as? GamesWidget)
        games.onNewBest?(GameResult(kind: .snake, score: 77))
        XCTAssertFalse(today.platy.celebrating)
        today.platy.stop()
    }

    /// A focus session that ends while an approval waits: its sound, but no celebration.
    func testFocusFinishedDuringApprovalDoesNotCelebrate() {
        let platy = PlatyMoodModel()
        var sounds = 0
        let focus = FocusModel(defaults: defaults(), onFinish: Moments.focusFinished(platy: platy, approvals: { 1 },
                                                                                      playSound: { sounds += 1 }))
        let start = Date()
        focus.start(minutes: 1, now: start)
        focus.reconcile(now: start.addingTimeInterval(61), announce: true)
        XCTAssertEqual(sounds, 1)
        XCTAssertFalse(platy.celebrating)
        platy.stop()
    }

    /// A chosen file that stopped working: Settings says why and the choice goes back to
    /// Platy chatter (saved), and the player does the same when it next plays.
    func testFallbackResetsTheChoiceAndSaysWhy() throws {
        let file = try wav("gone-too.wav", seconds: 0.3)
        let model = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(model.choose(file), .ok)
        XCTAssertEqual(model.choice, .custom)
        try FileManager.default.removeItem(at: file)
        model.preview()
        XCTAssertEqual(model.error, PlipValidation.unreadable.message)
        XCTAssertEqual(model.choice, .chatter)
        XCTAssertEqual(PlipSettings.load(from: defaults()).choice, .chatter)
        // A model opened later sees the same at once.
        let long = try wav("long-later.wav", seconds: 6)
        var s = PlipSettings.load(from: defaults())
        s.choice = .custom
        s.bookmark = try long.bookmarkData()
        s.save(to: defaults())
        let later = PlipSoundModel(defaults: defaults(), play: { _, _ in true })
        XCTAssertEqual(later.choice, .chatter)
        XCTAssertNotNil(later.error)
        // The player resets it too.
        s.choice = .custom
        s.enabled = true
        s.save(to: defaults())
        player().agentNeedsYou(session(term: nil))
        XCTAssertEqual(played.first?.0, CueSound.plip.url)
        XCTAssertEqual(PlipSettings.load(from: defaults()).choice, .chatter)
    }
}
