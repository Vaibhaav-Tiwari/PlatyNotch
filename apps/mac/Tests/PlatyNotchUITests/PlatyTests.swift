import AppKit
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

@MainActor
final class PlatyTests: XCTestCase {
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
        let suite = "PlatyTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let registry = WidgetRegistry(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
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

    func testDotPulsesOnlyWhenAsked() {
        let dot = AgentDotNSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        dot.configure(color: .systemGreen, pulses: true)
        XCTAssertTrue(dot.isPulsing)
        dot.configure(color: .systemGreen, pulses: false)
        XCTAssertFalse(dot.isPulsing)
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
}
