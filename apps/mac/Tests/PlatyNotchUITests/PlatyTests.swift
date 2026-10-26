import AppKit
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class PlatyTests: DefaultsTestCase {
    private func session(_ key: String, _ state: SessionState) -> Session {
        let t = Date(timeIntervalSince1970: 0)
        return Session(key: key, agent: "claude-code", agentName: "Claude Code", sessionID: key, state: state,
                       startedAt: t, updatedAt: t)
    }

    /// GamesWidget.onNewBest → celebrating for a few seconds, then back.
    func testCelebrationComesAndGoes() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = PlatyMoodModel(now: { now })
        model.celebrate()
        XCTAssertTrue(model.celebrating)
        XCTAssertEqual(model.mood(sessions: [], approvals: 0, musicPlaying: true, focusActive: false), .celebrating)
        XCTAssertEqual(model.mood(sessions: [], approvals: 1, musicPlaying: false, focusActive: false), .waiting)
        now = now.addingTimeInterval(PlatyMoodFlags.celebrationLength + 0.1)
        model.refresh()
        XCTAssertFalse(model.celebrating)
        model.stop()
    }

    /// The built-in games widget is wired to the shared Platy model.
    func testGamesNewBestCelebrates() throws {
        let registry = WidgetRegistry(defaults: defaults())
        let today = TodayServices(client: CoreClient(socketPath: "/nonexistent"))
        BuiltInWidgets.register(in: registry, store: AppStore(), today: today, persist: false)
        let games = try XCTUnwrap(registry.widget(GamesWidget.widgetID) as? GamesWidget)
        XCTAssertFalse(today.platy.celebrating)
        games.onNewBest?(GameResult(kind: .snake, score: 10))
        XCTAssertTrue(today.platy.celebrating)
        today.platy.stop()
    }

    func testFinishedSessionShowsDone() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let model = PlatyMoodModel(now: { now })
        model.sessionsChanged([session("a", .active)])
        XCTAssertFalse(model.justFinished)
        model.sessionsChanged([session("a", .idle)])
        XCTAssertTrue(model.justFinished)
        XCTAssertEqual(model.mood(sessions: [session("a", .idle)], approvals: 0, musicPlaying: false, focusActive: false),
                       .done)
        now = now.addingTimeInterval(PlatyMoodFlags.doneLength)
        model.refresh()
        XCTAssertFalse(model.justFinished)
        model.stop()
    }

    /// Followed, the model hears finishes from the app's one tracker, and shows done while
    /// the finish is under 10 minutes old and nothing works (Ruling 14).
    func testFollowsTheOneTracker() throws {
        var now = Date(timeIntervalSince1970: 1_000_000)   // 13:46 UTC: not night
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let model = PlatyMoodModel(now: { now }, calendar: utc)
        let activity = AgentActivityModel()
        model.follow(activity)
        activity.sessionsChanged([session("a", .active)], now: now)
        activity.sessionsChanged([session("a", .idle)], now: now)
        XCTAssertTrue(model.justFinished)
        now = now.addingTimeInterval(PlatyMoodFlags.doneLength + 60)
        model.refresh()
        XCTAssertFalse(model.justFinished)
        XCTAssertEqual(model.mood(sessions: [session("a", .idle)], approvals: 0, musicPlaying: false, focusActive: false),
                       .done, "still done: the finish is a minute old")
        XCTAssertEqual(model.mood(sessions: [session("a", .idle), session("b", .active)], approvals: 0,
                                  musicPlaying: false, focusActive: false), .working)
        now = now.addingTimeInterval(AgentFinishLog.window)
        XCTAssertEqual(model.mood(sessions: [session("a", .idle)], approvals: 0, musicPlaying: false, focusActive: false),
                       .idle)
        model.stop()
        activity.stop()
    }

    /// The hour comes from the injected calendar and follows a time zone change.
    func testHourFollowsCalendarAndTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let twoAM = Date(timeIntervalSince1970: 2 * 3600)   // 1970-01-01 02:00 UTC
        let model = PlatyMoodModel(now: { twoAM }, calendar: utc)
        XCTAssertEqual(model.hour, 2)
        XCTAssertEqual(model.mood(sessions: [], approvals: 0, musicPlaying: false, focusActive: false), .sleepy)
        model.timeZoneChanged(to: try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo")))
        XCTAssertEqual(model.hour, 11)
        XCTAssertEqual(model.mood(sessions: [], approvals: 0, musicPlaying: false, focusActive: false), .idle)
        model.stop()
    }

    /// The loop is a Core Animation keyframe animation: on while it should play, off
    /// otherwise (still frame). Waiting's loop holds one frame through its still half.
    func testLayerPlaysOnlyWhenAnimating() throws {
        let view = PlatyLayerNSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        view.configure(.init(mood: .working, size: 22, animates: true))
        XCTAssertTrue(view.isPlaying)
        view.configure(.init(mood: .working, size: 22, animates: false))
        XCTAssertFalse(view.isPlaying, "hidden panel or Reduce Motion: a still frame")
        view.configure(.init(mood: .idle, size: 22, animates: true))
        XCTAssertFalse(view.isPlaying, "idle is still")
        let waiting = PlatyFrames.frames(.waiting, size: 22, scale: 2)
        XCTAssertEqual(waiting.images.count, PlatyPoseValues.loop(.waiting).count)
        XCTAssertEqual(waiting.keyTimes.count, waiting.images.count + 1)
        XCTAssertEqual(try XCTUnwrap(waiting.keyTimes.last).doubleValue, 1)
        XCTAssertEqual(try XCTUnwrap(waiting.images.first).width, 44)
    }

    /// Waiting and done play their loop once (repeatCount 1), then hold the still frame;
    /// re-entering the mood plays it again. Other moods loop.
    func testPlaysOnceLoopEndsStill() throws {
        let view = PlatyLayerNSView(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        view.configure(.init(mood: .waiting, size: 22, animates: true))
        XCTAssertEqual(try XCTUnwrap(view.loopRepeatCount), 1)
        XCTAssertTrue(view.holdsStillAfterLoop)
        view.configure(.init(mood: .working, size: 22, animates: true))
        XCTAssertEqual(try XCTUnwrap(view.loopRepeatCount), .infinity)
        view.configure(.init(mood: .waiting, size: 22, animates: true))
        XCTAssertEqual(try XCTUnwrap(view.loopRepeatCount), 1, "the wave plays again")
        view.configure(.init(mood: .done, size: 22, animates: true))
        XCTAssertEqual(try XCTUnwrap(view.loopRepeatCount), 1)
    }

    func testDotPulsesOnlyWhenAsked() {
        let dot = AgentDotNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        dot.configure(color: .systemGreen, pulses: true)
        XCTAssertTrue(dot.isPulsing)
        dot.configure(color: .systemGreen, pulses: false)
        XCTAssertFalse(dot.isPulsing)
    }

    /// Final review A2: the ringing card's pulse is a Core Animation layer, on only when asked
    /// (the card passes `panelTicking && !reduceMotion`).
    func testRingPulseIsCoreAnimationOnlyWhenAsked() {
        let ring = RingPulseNSView(frame: NSRect(x: 0, y: 0, width: 46, height: 46))
        XCTAssertFalse(ring.isPulsing)
        ring.configure(color: .systemOrange, pulses: true)
        XCTAssertTrue(ring.isPulsing)
        ring.configure(color: .systemOrange, pulses: false)
        XCTAssertFalse(ring.isPulsing)
    }

    /// The frame loop runs only while the panel ticks, without Reduce Motion, for a moving mood.
    func testFrameLoopOnlyWhenVisibleAndMoving() {
        XCTAssertNotNil(PlatyView.frameInterval(mood: .working, ticking: true, reduceMotion: false))
        XCTAssertNil(PlatyView.frameInterval(mood: .working, ticking: false, reduceMotion: false), "hidden panel")
        XCTAssertNil(PlatyView.frameInterval(mood: .working, ticking: true, reduceMotion: true), "Reduce Motion")
        XCTAssertNil(PlatyView.frameInterval(mood: .idle, ticking: true, reduceMotion: false), "idle is still")
        XCTAssertEqual(PlatyView.frameInterval(mood: .sleepy, ticking: true, reduceMotion: false), 1)
        XCTAssertEqual(PlatyView.frameInterval(mood: .working, ticking: true, reduceMotion: false), 1.0 / 12)
        XCTAssertEqual(PlatyView.frameInterval(mood: .waiting, ticking: true, reduceMotion: false), 1.0 / 6)
    }

    /// C35: ten iconset images, 16 to 1024 px, named the way iconutil expects.
    func testIconsetEntries() {
        let names = PlatyRenders.iconsetEntries.map(\.0)
        XCTAssertEqual(names.count, 10)
        XCTAssertTrue(names.contains("icon_16x16.png"))
        XCTAssertTrue(names.contains("icon_512x512@2x.png"))
        let pixels = PlatyRenders.iconsetEntries.map { Int($0.1 * $0.2) }
        XCTAssertEqual(pixels.min(), 16)
        XCTAssertEqual(pixels.max(), 1024)
    }

    func testIconAndMoodsRender() throws {
        let data = try XCTUnwrap(PlatyRenders.png(PlatyAppIconView(size: 64), scale: 1))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(rep.pixelsWide, 64)
        // The corners are outside the rounded plate (transparent), the middle is not.
        XCTAssertLessThan(rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1, 0.1)
        XCTAssertGreaterThan(rep.colorAt(x: 32, y: 32)?.alphaComponent ?? 0, 0.9)
        for mood in PlatyMood.allCases {
            XCTAssertNotNil(PlatyRenders.png(PlatyCanvas(pose: .rest(mood), size: 22), scale: 2), "\(mood)")
        }
    }

    func testDetailLevels() {
        XCTAssertEqual(PlatyDetail(points: 16), .tiny)
        XCTAssertEqual(PlatyDetail(points: 22), .tiny)
        XCTAssertEqual(PlatyDetail(points: 48), .small)
        XCTAssertEqual(PlatyDetail(points: 96), .full)
    }

    // MARK: Agent pups (Task 29)

    func testPupForEveryAgentAndTone() {
        var count = 0
        for agent in AgentIdentity.allCases {
            for tone in StateTone.allCases {
                XCTAssertNotNil(PupImages.image(agent: agent, tone: tone, size: 28, scale: 2, dark: true),
                                "\(agent) \(tone)")
                count += 1
            }
        }
        XCTAssertEqual(count, 25)
    }

    func testPupsAreCached() throws {
        let a = try XCTUnwrap(PupImages.image(agent: .codex, tone: .working, size: 28, scale: 2, dark: false))
        let b = try XCTUnwrap(PupImages.image(agent: .codex, tone: .working, size: 28, scale: 2, dark: false))
        XCTAssertTrue(a === b)
        // Another agent is another picture.
        let c = try XCTUnwrap(PupImages.image(agent: .cursor, tone: .working, size: 28, scale: 2, dark: false))
        XCTAssertFalse(a === c)
    }

    /// The bandana is the agent's colour: the pixel at the knot differs between agents.
    func testPupBandanaFollowsTheAgent() throws {
        let claude = try XCTUnwrap(PupImages.image(agent: .claude, tone: .idle, size: 64, scale: 1, dark: true,
                                                   badge: false))
        let gemini = try XCTUnwrap(PupImages.image(agent: .gemini, tone: .idle, size: 64, scale: 1, dark: true,
                                                   badge: false))
        let knot = PlatyShapes.bandanaKnot
        let x = Int(knot.x * 0.64), y = Int(knot.y * 0.64)
        let a = try XCTUnwrap(NSBitmapImageRep(cgImage: claude).colorAt(x: x, y: y))
        let b = try XCTUnwrap(NSBitmapImageRep(cgImage: gemini).colorAt(x: x, y: y))
        XCTAssertNotEqual(a, b)
    }

    func testGalleryIncludesPups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-gallery-pups-\(getpid())")
        defer { try? FileManager.default.removeItem(at: dir) }
        guard case .success = PlatyRenders.writeGallery(to: dir) else { return XCTFail("gallery failed") }
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("pup-") }
        XCTAssertEqual(Set(names), Set(AgentIdentity.allCases.map { "pup-\($0.rawValue).png" }))
    }

    // MARK: Moments (Task 30)

    /// Every agent finishing is a 2-second moment, once, and never while an approval waits.
    func testAllAgentsFinishedIsAMoment() {
        var now = Date(timeIntervalSince1970: 2_000_000)
        // A reference the approvals closure reads (a captured var mutated later warns in Swift 6).
        final class Box { var approvals = 0 }
        let box = Box()
        let activity = AgentActivityModel()
        let platy = PlatyMoodModel(now: { now })
        activity.celebrateAllFinished(on: platy, approvals: { box.approvals }, now: { now })
        activity.sessionsChanged([session("a", .active)], now: now)
        XCTAssertFalse(platy.celebrating)
        activity.sessionsChanged([session("a", .idle)], now: now)
        XCTAssertTrue(platy.celebrating)
        now = now.addingTimeInterval(PlatyMoodFlags.celebrationLength + 0.1)
        platy.refresh()
        XCTAssertFalse(platy.celebrating)
        // With an approval waiting: no moment.
        box.approvals = 1
        activity.sessionsChanged([session("a", .active)], now: now)
        now = now.addingTimeInterval(30)
        activity.sessionsChanged([session("a", .idle)], now: now)
        XCTAssertFalse(platy.celebrating)
        platy.stop()
    }

    /// `celebrate()` still works as before (ungated), and the gated form drops repeats.
    func testCelebrateWrapperAndGate() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let platy = PlatyMoodModel(now: { now })
        XCTAssertTrue(platy.celebrate(.newBest(game: "snake", score: 9), approvalsPending: 0))
        XCTAssertFalse(platy.celebrate(.newBest(game: "snake", score: 9), approvalsPending: 0))
        XCTAssertFalse(platy.celebrate(.focusComplete(endedAt: now), approvalsPending: 1))
        platy.celebrate()
        XCTAssertTrue(platy.celebrating)
        platy.stop()
    }

    /// The focus session's end plays its sound and sends the moment.
    func testFocusCompleteIsAMoment() {
        let platy = PlatyMoodModel()
        var sounds = 0
        let focus = FocusModel(defaults: defaults(), onFinish: Moments.focusFinished(platy: platy, approvals: { 0 },
                                                                                      playSound: { sounds += 1 }))
        let start = Date()
        focus.start(minutes: 1, now: start)
        XCTAssertEqual(sounds, 0)
        focus.reconcile(now: start.addingTimeInterval(61), announce: true)
        XCTAssertEqual(sounds, 1)
        XCTAssertTrue(platy.celebrating)
        platy.stop()
    }
}
