import Foundation
import XCTest
@testable import PlatyNotchKit

final class PlatyMoodTests: XCTestCase {
    private func mood(_ sessions: [SessionState] = [], approvals: Int = 0, music: Bool = false, focus: Bool = false,
                      finished: Bool = false, hour: Int = 12, celebrating: Bool = false) -> PlatyMood {
        PlatyMoodResolver.mood(sessions: sessions, approvalsPending: approvals, musicPlaying: music,
                               focusActive: focus, justFinished: finished, hour: hour, celebrating: celebrating)
    }

    // MARK: - Resolver (brief)

    func testWaitingBeatsEverything() {
        XCTAssertEqual(mood([.active], approvals: 1, music: true, focus: true, finished: true, hour: 2, celebrating: true),
                       .waiting)
        XCTAssertEqual(mood([.active, .blocked], music: true, focus: true, finished: true), .waiting)
        XCTAssertEqual(mood([.waitingInput], focus: true, finished: true), .waiting)
    }

    func testDoneBeatsWorking() {
        XCTAssertEqual(mood([.active], finished: true), .done)
        XCTAssertEqual(mood([.active]), .working)
    }

    func testMusicDances() {
        XCTAssertEqual(mood(music: true), .dancing)
        XCTAssertEqual(mood([.active], music: true), .working, "agents at work beat music")
        XCTAssertEqual(mood(music: true, hour: 2), .dancing, "music beats night")
    }

    func testNightSleepy() {
        XCTAssertEqual(mood([.idle, .exited], hour: 2), .sleepy)
        XCTAssertEqual(mood(hour: 23), .sleepy)
        XCTAssertEqual(mood(hour: 5), .sleepy)
        XCTAssertEqual(mood(hour: 6), .idle)
        XCTAssertEqual(mood(hour: 22), .idle)
        XCTAssertEqual(mood([.active], hour: 2), .working)
    }

    func testFocusBeatsWorking() {
        XCTAssertEqual(mood([.active], focus: true), .focused)
        XCTAssertEqual(mood([.active], focus: true, finished: true), .done)
    }

    // MARK: - Celebrating (Task 13 ruling: GamesWidget.onNewBest)

    func testCelebratingAfterNewBest() {
        XCTAssertEqual(mood(celebrating: true), .celebrating)
        XCTAssertEqual(mood([.active], music: true, focus: true, finished: true, hour: 2, celebrating: true),
                       .celebrating, "a new best beats everything but a waiting agent")
        XCTAssertEqual(mood([.blocked], celebrating: true), .waiting)
    }

    func testCelebrationLastsAFewSeconds() {
        let start = Date(timeIntervalSince1970: 1000)
        var flags = PlatyMoodFlags()
        flags.celebrate(at: start)
        XCTAssertTrue(flags.celebrating(at: start.addingTimeInterval(PlatyMoodFlags.celebrationLength - 0.1)))
        XCTAssertFalse(flags.celebrating(at: start.addingTimeInterval(PlatyMoodFlags.celebrationLength)))
        XCTAssertGreaterThanOrEqual(PlatyMoodFlags.celebrationLength, 2)
        XCTAssertLessThanOrEqual(PlatyMoodFlags.celebrationLength, 6)
        XCTAssertEqual(flags.nextChange(after: start), start.addingTimeInterval(PlatyMoodFlags.celebrationLength))
        XCTAssertNil(flags.nextChange(after: start.addingTimeInterval(60)))
    }

    // MARK: - AgentsLive decision: removed; the resolver reads session states directly

    /// AgentsLive (unused since Task 1a) kept only active and blocked, so an agent waiting
    /// for input looked idle to it. The resolver takes every session state from the store.
    func testResolverReadsEverySessionState() {
        XCTAssertEqual(mood([.waitingInput]), .waiting)
        XCTAssertEqual(mood([.blocked]), .waiting)
        XCTAssertEqual(mood([.active, .idle]), .working)
        XCTAssertEqual(mood([.idle, .exited]), .idle)
    }

    // MARK: - Just finished

    func testFinishWatchSeesActiveToIdle() {
        let t0 = Date(timeIntervalSince1970: 0)
        var watch = PlatyFinishWatch()
        XCTAssertFalse(watch.update(["a": .active, "b": .idle]), "first look: nothing finished")
        XCTAssertFalse(watch.update(["a": .active, "b": .idle]))
        XCTAssertFalse(watch.update(["a": .blocked, "b": .idle]), "blocked is not finished")
        XCTAssertFalse(watch.update(["a": .active, "b": .idle, "c": .idle]), "a new idle session is not finished")
        XCTAssertTrue(watch.update(["a": .idle, "b": .idle, "c": .idle]))
        XCTAssertFalse(watch.update(["a": .idle, "b": .idle, "c": .idle]), "once")
        XCTAssertFalse(watch.update(["c": .active]))
        XCTAssertTrue(watch.update(["c": .exited]))
        var flags = PlatyMoodFlags()
        flags.finish(at: t0)
        XCTAssertTrue(flags.justFinished(at: t0.addingTimeInterval(1)))
        XCTAssertFalse(flags.justFinished(at: t0.addingTimeInterval(PlatyMoodFlags.doneLength)))
    }

    func testNextChangeIsTheEarliestExpiry() {
        let t0 = Date(timeIntervalSince1970: 0)
        var flags = PlatyMoodFlags()
        flags.finish(at: t0)
        flags.celebrate(at: t0.addingTimeInterval(1))
        let first = min(PlatyMoodFlags.doneLength, 1 + PlatyMoodFlags.celebrationLength)
        XCTAssertEqual(flags.nextChange(after: t0), t0.addingTimeInterval(first))
    }

    // MARK: - Poses (C34: plain Doubles in Kit)

    func testPoseIsPeriodic() {
        let period = PlatyMood.working.period
        XCTAssertGreaterThan(period, 0)
        for t in stride(from: 0.0, through: 7.0, by: 0.37) {
            XCTAssertEqual(PlatyPoseValues.at(.working, time: t), PlatyPoseValues.at(.working, time: t + period), "t=\(t)")
        }
    }

    func testEveryAnimatedMoodIsPeriodicAndMoves() {
        for m in PlatyMood.allCases where m.animates {
            let p = m.period
            var distinct = Set<String>()
            for t in stride(from: 0.05, through: 3 * p, by: p / 7) {
                let a = PlatyPoseValues.at(m, time: t)
                XCTAssertEqual(a, PlatyPoseValues.at(m, time: t + p), "\(m) t=\(t)")
                XCTAssertEqual(a, PlatyPoseValues.at(m, time: t + 5 * p), "\(m) t=\(t)")
                distinct.insert("\(a)")
            }
            XCTAssertGreaterThan(distinct.count, 1, "\(m) animates but never changes")
        }
    }

    func testStaticMoodsDoNotTick() {
        for m in [PlatyMood.idle, .focused] {
            XCTAssertFalse(m.animates, "\(m)")
            XCTAssertNil(m.frameInterval, "\(m): costs nothing at rest")
            XCTAssertEqual(PlatyPoseValues.at(m, time: 0), PlatyPoseValues.at(m, time: 12.3))
            XCTAssertEqual(PlatyPoseValues.at(m, time: 0), PlatyPoseValues.rest(m))
        }
    }

    /// The idle budget: sleepy (night, nothing live) breathes at no more than 1 fps.
    func testSleepyIsSlow() throws {
        let interval = try XCTUnwrap(PlatyMood.sleepy.frameInterval)
        XCTAssertGreaterThanOrEqual(interval, 1)
        XCTAssertGreaterThanOrEqual(PlatyMood.sleepy.period, 4 * interval)
        for m in PlatyMood.allCases where m.animates {
            let i = try XCTUnwrap(m.frameInterval, "\(m)")
            XCTAssertGreaterThanOrEqual(i, 1.0 / 30, "\(m): at most 30 fps")
        }
    }

    /// Reduce Motion and paused panels draw `rest`: the mood must still read.
    func testRestFramesKeepTheMoodCues() {
        XCTAssertEqual(PlatyPoseValues.rest(.waiting).tint, .amber)
        XCTAssertTrue(PlatyPoseValues.rest(.dancing).headphones)
        XCTAssertEqual(PlatyPoseValues.rest(.sleepy).eyesOpen, 0)
        XCTAssertTrue(PlatyPoseValues.rest(.sleepy).zzz)
        XCTAssertTrue(PlatyPoseValues.rest(.done).check)
        XCTAssertGreaterThan(PlatyPoseValues.rest(.celebrating).sparkle, PlatyPoseValues.rest(.done).sparkle)
        XCTAssertLessThan(PlatyPoseValues.rest(.focused).eyesOpen, 1)
        XCTAssertEqual(PlatyPoseValues.rest(.idle).tint, .none)
        for m in PlatyMood.allCases where m != .waiting {
            XCTAssertEqual(PlatyPoseValues.at(m, time: 0.4).tint, .none, "\(m)")
        }
    }

    func testMoodCues() {
        for t in stride(from: 0.0, through: 4.0, by: 0.25) {
            XCTAssertEqual(PlatyPoseValues.at(.waiting, time: t).tint, .amber)
            XCTAssertTrue(PlatyPoseValues.at(.dancing, time: t).headphones)
            XCTAssertEqual(PlatyPoseValues.at(.sleepy, time: t).eyesOpen, 0)
            XCTAssertTrue(PlatyPoseValues.at(.done, time: t).check)
        }
        let jump = stride(from: 0.0, to: PlatyMood.celebrating.period, by: 0.05)
            .map { PlatyPoseValues.at(.celebrating, time: $0).bounce }.max() ?? 0
        let bob = stride(from: 0.0, to: PlatyMood.working.period, by: 0.05)
            .map { PlatyPoseValues.at(.working, time: $0).bounce }.max() ?? 0
        XCTAssertGreaterThan(jump, 2 * bob, "celebrating jumps, working bobs")
        let taps = stride(from: 0.0, to: PlatyMood.waiting.period, by: 0.05)
            .map { PlatyPoseValues.at(.waiting, time: $0).tailWag }
        XCTAssertGreaterThan((taps.max() ?? 0) - (taps.min() ?? 0), 0.5, "the tail taps")
    }

    // MARK: - The agents ear with Platy

    func testEarFitsPlatyAndDots() {
        // Plenty of room: every dot and the +n.
        XCTAssertEqual(PlatyEarFit(earWidth: 86, dots: 3, overflow: 2), PlatyEarFit(dots: 3, showsOverflow: true))
        // Compact beside a notch (40 - 6): Platy and one dot.
        let compact = PlatyEarFit(earWidth: 34, dots: 3, overflow: 0)
        XCTAssertEqual(compact.dots, 1)
        XCTAssertFalse(compact.showsOverflow)
        XCTAssertEqual(PlatyEarFit(earWidth: 10, dots: 3, overflow: 1), PlatyEarFit(dots: 0, showsOverflow: false))
        for w in stride(from: 0.0, through: 120.0, by: 1) {
            let fit = PlatyEarFit(earWidth: CGFloat(w), dots: 3, overflow: 4)
            XCTAssertLessThanOrEqual(fit.width, max(CGFloat(w), PlatyEarFit.platy), "w=\(w)")
        }
    }

    // MARK: - Settings (C36)

    func testShowPlatyDefaultsOnAndDecodes() throws {
        XCTAssertTrue(AppearanceSettings().showPlaty)
        let old = try JSONDecoder().decode(AppearanceSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.showPlaty, "settings saved before Task 13 keep Platy on")
        var off = AppearanceSettings()
        off.showPlaty = false
        let back = try JSONDecoder().decode(AppearanceSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(back.showPlaty)
        XCTAssertFalse(off.needsRebuild(from: AppearanceSettings()), "applied live")
    }
}
