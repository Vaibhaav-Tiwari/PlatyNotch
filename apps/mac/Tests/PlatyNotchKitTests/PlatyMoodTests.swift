import AppKit
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
        XCTAssertEqual(mood([.active], music: true), .workingToMusic, "agents at work with music: working, headphones on")
        XCTAssertEqual(mood([.active], music: true, finished: true), .done)
        XCTAssertEqual(mood([.active, .blocked], music: true), .waiting)
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

    /// The core removes a session only 10 min after it exited (store.Sweep); an active
    /// session vanishes only from a snapshot after a core restart, which is not a finish.
    func testRemovalWhileActiveIsNotDone() {
        var watch = PlatyFinishWatch()
        _ = watch.update(["a": .active, "b": .idle])
        XCTAssertFalse(watch.update(["b": .idle]))
        XCTAssertFalse(watch.update([:]))
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
        for m in PlatyMood.allCases where m.animates && !m.playsOnce {
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

    /// The keyframes Core Animation plays (the app draws nothing per frame).
    func testLoopKeyframes() throws {
        let working = PlatyPoseValues.loop(.working)
        XCTAssertEqual(working.first?.time, 0)
        XCTAssertEqual(working.count, Int((PlatyMood.working.period / PlatyMood.pillTick).rounded(.up)))
        for (t, pose) in working { XCTAssertEqual(pose, PlatyPoseValues.at(.working, time: t)) }
        // Waiting: one 2 s wave at 6 fps, played once (`playsOnce`).
        let waiting = PlatyPoseValues.loop(.waiting)
        let p = PlatyMood.waiting.period
        XCTAssertEqual(p, 2)
        let interval = try XCTUnwrap(PlatyMood.waiting.frameInterval)
        XCTAssertGreaterThan(waiting.count, 4)
        XCTAssertLessThanOrEqual(waiting.count, Int((p / interval).rounded(.up)))
        XCTAssertTrue(waiting.allSatisfy { $0.time < p })
        XCTAssertEqual(PlatyPoseValues.loop(.idle).count, 1)
        XCTAssertEqual(PlatyPoseValues.loop(.sleepy).count, 4, "1 fps over 4 s")
        for m in PlatyMood.allCases {
            let times = PlatyPoseValues.loop(m).map(\.time)
            XCTAssertEqual(times, times.sorted(), "\(m)")
            XCTAssertTrue(times.allSatisfy { $0 < m.period }, "\(m)")
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
            XCTAssertGreaterThanOrEqual(i, 1.0 / 12, "\(m): the pill's 12 fps budget (MusicBars)")
        }
        // Waiting can last hours (an unanswered approval): 6 fps at most.
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(PlatyMood.waiting.frameInterval), 1.0 / 6)
    }

    /// Waiting (spec 8.1): the flag waves once over 2 s, then Platy holds still with the
    /// flag up; done shows its check once. Neither loops.
    func testWaitingWavesOnceThenHolds() {
        XCTAssertTrue(PlatyMood.waiting.playsOnce)
        XCTAssertTrue(PlatyMood.done.playsOnce)
        for m in PlatyMood.allCases where m != .waiting && m != .done { XCTAssertFalse(m.playsOnce, "\(m)") }
        XCTAssertEqual(PlatyPoseValues.at(.waiting, time: 2.5), PlatyPoseValues.rest(.waiting))
        XCTAssertEqual(PlatyPoseValues.at(.waiting, time: 600), PlatyPoseValues.rest(.waiting))
        let moving = stride(from: 0.0, to: 2.0, by: 0.1).map { PlatyPoseValues.at(.waiting, time: $0) }
        XCTAssertTrue(moving.contains { $0 != PlatyPoseValues.rest(.waiting) }, "the pose moves between 0 and 2")
        XCTAssertGreaterThan(Set(moving.map { "\($0)" }).count, 3)
    }

    /// Moving moods step on the shared 12 fps grid (Platy and the pill's timelines share frames).
    func testFramesStepOnTheSharedGrid() throws {
        let w = try XCTUnwrap(PlatyMood.working.frameInterval)
        XCTAssertEqual(w, PlatyMood.pillTick)
        XCTAssertEqual(PlatyMood.working.nextFrame(after: 3.3), 40 * w, accuracy: 1e-9)
        XCTAssertEqual(PlatyMood.working.nextFrame(after: 40 * w), 41 * w, accuracy: 1e-9, "always moves on")
        let interval = try XCTUnwrap(PlatyMood.waiting.frameInterval)
        let n0 = PlatyMood.waiting.nextFrame(after: 0.1)
        XCTAssertEqual((n0 / interval).rounded() * interval, n0, accuracy: 1e-9, "on the shared grid")
    }

    func testWaitingRestHasFlag() {
        XCTAssertTrue(PlatyPoseValues.rest(.waiting).flag)
        XCTAssertEqual(PlatyPoseValues.rest(.waiting).tint, .amber)
        for t in stride(from: 0.0, through: 3.0, by: 0.25) {
            XCTAssertTrue(PlatyPoseValues.at(.waiting, time: t).flag, "the flag stays up through the wave")
        }
        for m in PlatyMood.allCases where m != .waiting { XCTAssertFalse(PlatyPoseValues.rest(m).flag, "\(m)") }
    }

    func testDoneHoldsAfterOneLoop() {
        let p = PlatyMood.done.period
        XCTAssertEqual(PlatyPoseValues.at(.done, time: p + 0.3), PlatyPoseValues.rest(.done))
        XCTAssertTrue(PlatyPoseValues.at(.done, time: 0.3 * p).check)
        XCTAssertNotEqual(PlatyPoseValues.at(.done, time: 0.25 * p), PlatyPoseValues.rest(.done), "it plays once")
    }

    /// Ruling 14: an agent that finished in the last 10 minutes shows done while nothing
    /// works or needs you.
    func testRecentFinishShowsDoneOnlyWhenNothingWorks() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        var log = AgentFinishLog()
        log.record(SessionChanges(finished: ["a"], enteredNeedsYou: [], allFinished: true),
                   now: now.addingTimeInterval(-300))
        let flags = PlatyMoodFlags()
        func moodFor(_ states: [SessionState]) -> PlatyMood {
            let done = PlatyMoodResolver.showsDone(flags: flags, log: log, sessions: states, now: now)
            return mood(states, finished: done)
        }
        XCTAssertEqual(moodFor([.idle]), .done)
        XCTAssertEqual(moodFor([]), .done)
        XCTAssertEqual(moodFor([.idle, .active]), .working)
        XCTAssertEqual(moodFor([.waitingInput]), .waiting)
        XCTAssertFalse(PlatyMoodResolver.showsDone(flags: flags, log: log, sessions: [.idle],
                                                   now: now.addingTimeInterval(301)), "the window ran out")
        var fresh = PlatyMoodFlags()
        fresh.finish(at: now)
        XCTAssertTrue(PlatyMoodResolver.showsDone(flags: fresh, log: AgentFinishLog(), sessions: [.active], now: now),
                      "the 4 s flag still shows done beside a working session")
    }

    /// Reduce Motion and paused panels draw `rest`: the mood must still read.
    func testRestFramesKeepTheMoodCues() {
        // Working: the water line under Platy (paws are not drawn at pill size).
        XCTAssertTrue(PlatyPoseValues.rest(.working).water)
        for t in stride(from: 0.0, through: 2.0, by: 0.1) {
            XCTAssertTrue(PlatyPoseValues.at(.working, time: t).water)
        }
        for m in PlatyMood.allCases where m != .working && m != .workingToMusic {
            XCTAssertFalse(PlatyPoseValues.rest(m).water, "\(m)")
        }
        XCTAssertEqual(PlatyPoseValues.rest(.waiting).tint, .amber)
        XCTAssertTrue(PlatyPoseValues.rest(.dancing).headphones)
        XCTAssertTrue(PlatyPoseValues.rest(.workingToMusic).headphones)
        XCTAssertTrue(PlatyPoseValues.rest(.workingToMusic).water)
        XCTAssertFalse(PlatyPoseValues.rest(.working).headphones)
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
            XCTAssertTrue(PlatyPoseValues.at(.workingToMusic, time: t).headphones)
            XCTAssertTrue(PlatyPoseValues.at(.workingToMusic, time: t).water)
            XCTAssertEqual(PlatyPoseValues.at(.sleepy, time: t).eyesOpen, 0)
            XCTAssertTrue(PlatyPoseValues.at(.done, time: t).check)
        }
        let jump = stride(from: 0.0, to: PlatyMood.celebrating.period, by: 0.05)
            .map { PlatyPoseValues.at(.celebrating, time: $0).bounce }.max() ?? 0
        let bob = stride(from: 0.0, to: PlatyMood.working.period, by: 0.05)
            .map { PlatyPoseValues.at(.working, time: $0).bounce }.max() ?? 0
        XCTAssertGreaterThan(jump, 2 * bob, "celebrating jumps, working bobs")
        let wave = stride(from: 0.0, to: PlatyMood.waiting.period, by: 0.05)
            .map { PlatyPoseValues.at(.waiting, time: $0).flagAngle }
        XCTAssertGreaterThan((wave.max() ?? 0) - (wave.min() ?? 0), 10, "the flag waves")
    }

    // MARK: - The agents ear with Platy

    func testEarFitsPlatyAndDots() {
        // Plenty of room: every dot and the +n.
        XCTAssertEqual(PlatyEarFit(earWidth: 86, dots: 3, overflow: 2), PlatyEarFit(dots: 3, overflowCount: 2, badge: false))
        XCTAssertEqual(PlatyEarFit(earWidth: 86, dots: 2, overflow: 0), PlatyEarFit(dots: 2, overflowCount: 0, badge: false))
        XCTAssertEqual(PlatyEarFit(earWidth: 34, dots: 1, overflow: 0), PlatyEarFit(dots: 1, overflowCount: 0, badge: false))
        // Room for some dots and the label: the squeezed-out dots join the "+n". (The label
        // is 22 pt at the 11 pt floor: 56 holds three dots alone, or one dot and the label.)
        XCTAssertEqual(PlatyEarFit(earWidth: 56, dots: 3, overflow: 0), PlatyEarFit(dots: 3, overflowCount: 0, badge: false))
        XCTAssertEqual(PlatyEarFit(earWidth: 56, dots: 3, overflow: 4), PlatyEarFit(dots: 1, overflowCount: 6, badge: false))
        XCTAssertEqual(PlatyEarFit(earWidth: 52, dots: 3, overflow: 0), PlatyEarFit(dots: 0, overflowCount: 3, badge: false))
        // Compact beside a notch (40 - 6): no room for the label, so "+n" is a badge on Platy
        // and no dots are drawn, leaving the ear's room to the badge.
        XCTAssertEqual(PlatyEarFit(earWidth: 34, dots: 3, overflow: 0), PlatyEarFit(dots: 0, overflowCount: 3, badge: true))
        XCTAssertEqual(PlatyEarFit(earWidth: 10, dots: 3, overflow: 1), PlatyEarFit(dots: 0, overflowCount: 4, badge: true))
        for w in stride(from: 0.0, through: 120.0, by: 1) {
            for dots in 0...3 {
                for overflow in [0, 1, 4] {
                    let fit = PlatyEarFit(earWidth: CGFloat(w), dots: dots, overflow: overflow)
                    XCTAssertLessThanOrEqual(fit.width, max(CGFloat(w), PlatyEarFit.platy), "w=\(w)")
                    XCTAssertEqual(fit.dots + fit.overflowCount, dots + overflow, "every session is counted, w=\(w)")
                }
            }
        }
    }

    /// The width the pill draws for a badge: 11 pt bold rounded text, rounded up, plus
    /// `badgePadding` each side.
    private func badgeWidth(_ text: String) throws -> CGFloat {
        let base = NSFont.systemFont(ofSize: 11, weight: .bold)
        let descriptor = try XCTUnwrap(base.fontDescriptor.withDesign(.rounded))
        let font = try XCTUnwrap(NSFont(descriptor: descriptor, size: 11))
        return NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up)
            + 2 * PlatyEarFit.badgePadding
    }

    /// The Compact pill's badge fits from Platy's centre to the pill's outer edge at the
    /// 34 pt ear (40 less the 6 pt padding), for one and two digits and "99+".
    func testBadgeFitsCompactEar() throws {
        let pad = PanelLayout.pillPadding(hasNotch: true)
        let room = PlatyEarFit.badgeRoom(earWidth: 34, outerPadding: pad)
        XCTAssertEqual(room, 29)
        XCTAssertEqual(PlatyEarFit.badgeText(150), "99+")
        XCTAssertEqual(PlatyEarFit.badgeText(99), "+99")
        for count in [9, 11, 40, 99, 150] {
            let text = PlatyEarFit.badgeText(count)
            XCTAssertLessThanOrEqual(try badgeWidth(text), room, text)
        }
    }

    /// At every pill width beside a notch, every badge stays between the hardware notch
    /// edge and the pill's outer edge.
    func testBadgeNeverCrossesNotchOrPillEdge() throws {
        let pad = PanelLayout.pillPadding(hasNotch: true)
        for w in AppearanceSettings.PillWidth.allCases {
            let earWidth = PanelLayout.ear(w) - pad
            for count in 1...150 {
                let width = try badgeWidth(PlatyEarFit.badgeText(count))
                let start = PlatyEarFit.badgeOffset(earWidth: earWidth, outerPadding: pad, badgeWidth: width)
                XCTAssertGreaterThanOrEqual(start, 0, "crosses the notch: \(w) \(count)")
                XCTAssertLessThanOrEqual(start + width, earWidth + pad, "crosses the pill's edge: \(w) \(count)")
                XCTAssertEqual(start, PlatyEarFit.platy / 2, "starts at Platy's centre: \(w) \(count)")
            }
        }
    }

    /// Feedback 5: with many sessions (6, 12, 40) Platy still shows in the pill at every
    /// Appearance › Pill width, beside a notch and without one, and every session is counted.
    func testPlatyShowsWithManySessionsAtEveryPillWidth() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visible = CGRect(x: 0, y: 0, width: 1512, height: 950)
        let left = CGRect(x: 0, y: 950, width: 654, height: 32)
        let right = CGRect(x: 858, y: 950, width: 654, height: 32)
        let ext = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let extVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for count in [6, 12, 40] {
            let sessions = (0..<count).map { i in
                Session(key: "s\(i)", agent: "claude-code", agentName: "Claude Code", sessionID: "s\(i)",
                        state: i % 2 == 0 ? .active : .idle, startedAt: start, updatedAt: start)
            }
            let dots = PillDots(sessions: sessions)
            for w in AppearanceSettings.PillWidth.allCases {
                let layouts = [
                    PanelLayout(screenFrame: screen, visibleFrame: visible, auxLeft: left, auxRight: right, pillWidth: w),
                    PanelLayout(screenFrame: ext, visibleFrame: extVisible, auxLeft: nil, auxRight: nil, pillWidth: w),
                ]
                for l in layouts {
                    let ear = l.liveEarWidth
                    let fit = PlatyEarFit(earWidth: ear, dots: dots.dots.count, overflow: dots.overflow)
                    let label = "\(count) sessions, \(w), notch=\(l.hasNotch), ear=\(ear)"
                    XCTAssertGreaterThanOrEqual(ear, PlatyEarFit.platy, "Platy fits the ear: " + label)
                    XCTAssertLessThanOrEqual(fit.width, ear, label)
                    XCTAssertEqual(fit.dots + fit.overflowCount, count, "every session counted: " + label)
                }
            }
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
