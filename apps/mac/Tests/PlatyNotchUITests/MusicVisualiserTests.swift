import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Never a real process tap: every visualiser here gets `FakeTap`.
@MainActor
final class FakeTap: AudioTapping {
    var starts = 0
    var stops = 0
    var running = false
    var fail = false
    var handler: AudioSampleHandler?

    func start(onSamples: @escaping AudioSampleHandler) throws {
        starts += 1
        if fail { throw SystemAudioTap.TapError.coreAudio("fake", -1) }
        running = true
        handler = onSamples
    }

    func stop() {
        stops += 1
        running = false
        handler = nil
    }

    /// Delivers `samples` as the tap thread would.
    func deliver(_ samples: [Float], channels: Int = 1, rate: Double = 48_000) {
        samples.withUnsafeBufferPointer { handler?($0, channels, rate) }
    }
}

/// Stands in for `Task.sleep` in the stop grace: nothing wakes until `fire()`.
@MainActor
final class ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var pending: Int { waiting.count }

    func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets newly scheduled tasks reach their sleep.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    /// Ends every sleep, then lets the woken tasks run.
    func fire() async {
        await settle()
        let w = waiting
        waiting = []
        for c in w { c.resume() }
        for _ in 0..<5 { await Task.yield() }
    }
}

@MainActor
final class MusicVisualiserTests: DefaultsTestCase {
    static let build = "dr:test-build"
    private var sleeper = ManualSleeper()

    private func make(enabled: Bool = false, prime: TimeInterval = 0.05) -> (MusicVisualiser, () -> [FakeTap], UserDefaults) {
        let d = defaults()
        d.set(enabled, forKey: MusicVisualiser.enabledKey)
        if enabled { d.set(Self.build, forKey: MusicVisualiser.stampKey) }   // granted to this build
        var taps: [FakeTap] = []
        let sleeper = self.sleeper
        let v = MusicVisualiser(defaults: d, identity: Self.build, primeDuration: prime,
                                sleep: { await sleeper.sleep($0) }, makeTap: {
            let t = FakeTap()
            taps.append(t)
            return t
        })
        return (v, { taps }, d)
    }

    func testOffByDefaultAndNoTapOnPlay() {
        let d = defaults()
        var made = 0
        let v = MusicVisualiser(defaults: d, makeTap: { made += 1; return FakeTap() })
        XCTAssertFalse(v.enabled)
        v.setWidgetRunning(true)
        v.setPlaying(true)                            // first play
        v.setViewer(UUID(), visible: true)            // bars on screen
        XCTAssertEqual(made, 0, "with the toggle off no tap (and no prompt) ever happens")
        XCTAssertFalse(v.isRunning)
    }

    func testTurningOnPrimesOnceThenStopsWhenNothingShows() async throws {
        let (v, taps, d) = make()
        v.setWidgetRunning(true)
        v.setEnabled(true)
        XCTAssertTrue(d.bool(forKey: MusicVisualiser.enabledKey))
        XCTAssertEqual(taps().count, 1, "the prompt belongs to turning the toggle on")
        XCTAssertTrue(v.isRunning)
        let graceStarted = await eventually { sleeper.pending > 0 }
        XCTAssertTrue(graceStarted, "priming over: the stop grace starts")
        XCTAssertTrue(v.isRunning, "the tap outlives priming by the grace")
        await sleeper.fire()
        XCTAssertFalse(v.isRunning, "nothing playing or visible: the tap stops after priming")
        XCTAssertEqual(taps()[0].stops, 1)
    }

    func testRunsOnlyWhilePlayingAndVisible() async {
        let (v, taps, _) = make(enabled: true)   // turned on in an earlier session: no priming
        v.setWidgetRunning(true)
        XCTAssertTrue(taps().isEmpty)
        let pill = UUID(), tile = UUID()
        v.setViewer(pill, visible: true)
        XCTAssertTrue(taps().isEmpty, "visible but not playing")
        v.setPlaying(true)
        XCTAssertEqual(taps().count, 1)
        XCTAssertTrue(v.isRunning)
        v.setViewer(tile, visible: true)
        v.setViewer(pill, visible: false)
        XCTAssertTrue(v.isRunning, "the tile still shows bars")
        v.setViewer(tile, visible: false)
        await sleeper.fire()
        XCTAssertFalse(v.isRunning, "neither the pill nor the tile is visible: the tap stops")
        XCTAssertEqual(taps()[0].stops, 1)
        v.setViewer(tile, visible: true)
        XCTAssertEqual(taps().count, 2, "a fresh tap when bars show again")
        v.setPlaying(false)
        await sleeper.fire()
        XCTAssertFalse(v.isRunning, "paused: the tap stops")
    }

    /// The pill disappears just before the panel's tile appears (or the other way round):
    /// within the grace the same tap carries on.
    func testGraceKeepsTheTapAcrossTransitions() async {
        let (v, taps, _) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        let pill = UUID(), tile = UUID()
        v.setViewer(pill, visible: true)
        v.setViewer(pill, visible: false)    // panel opens: pill gone first
        await sleeper.settle()
        XCTAssertTrue(v.isRunning, "still within the grace")
        XCTAssertEqual(sleeper.pending, 1)
        v.setViewer(tile, visible: true)     // tile appears
        await sleeper.fire()                 // the cancelled grace wakes and does nothing
        XCTAssertTrue(v.isRunning)
        XCTAssertEqual(taps().count, 1, "no destroy and rebuild")
        XCTAssertEqual(taps()[0].stops, 0)
        // a second hide schedules a fresh grace, which does stop it
        v.setViewer(tile, visible: false)
        XCTAssertTrue(v.isRunning)
        await sleeper.fire()
        XCTAssertFalse(v.isRunning)
        XCTAssertEqual(taps()[0].stops, 1)
    }

    func testToggleOffDuringGraceStopsAtOnce() async {
        let (v, taps, _) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        let id = UUID()
        v.setViewer(id, visible: true)
        v.setViewer(id, visible: false)
        XCTAssertTrue(v.isRunning)
        v.setEnabled(false)
        XCTAssertFalse(v.isRunning, "turning the toggle off never waits for the grace")
        XCTAssertEqual(taps()[0].stops, 1)
        await sleeper.fire()
        XCTAssertEqual(taps()[0].stops, 1, "the stale grace does nothing")
    }

    func testTogglingOffStopsAtOnce() {
        let (v, taps, d) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        XCTAssertTrue(v.isRunning)
        v.setEnabled(false)
        XCTAssertFalse(v.isRunning)
        XCTAssertEqual(sleeper.pending, 0, "no grace")
        XCTAssertEqual(taps()[0].stops, 1)
        XCTAssertFalse(d.bool(forKey: MusicVisualiser.enabledKey))
        XCTAssertEqual(v.levels, Array(repeating: 0, count: MusicVisualiser.bandCount))
    }

    func testWidgetStopStopsTheTap() {
        let (v, taps, _) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        v.setWidgetRunning(false)   // also what quitting does (registry.stopAll → stop)
        XCTAssertFalse(v.isRunning)
        XCTAssertEqual(taps()[0].stops, 1)
        XCTAssertEqual(sleeper.pending, 0, "no grace")
    }

    /// Final review B2: the toggle is saved with this build's identity; a build that was
    /// not granted (an update, a rebuild, a toggle saved before stamps) starts with it off,
    /// shows "Turn on again", and never taps on play.
    func testToggleOnSavesTheGrantStamp() {
        let (v, _, d) = make()
        v.setWidgetRunning(true)
        v.setEnabled(true)
        XCTAssertEqual(d.string(forKey: MusicVisualiser.stampKey), Self.build)
        v.setEnabled(false)
        XCTAssertNil(d.string(forKey: MusicVisualiser.stampKey), "off forgets the grant")
    }

    func testOtherBuildOrMissingStampTurnsOffAtLaunch() {
        for stamp in [nil, "dr:an-older-build", ""] as [String?] {
            let d = defaults()
            d.set(true, forKey: MusicVisualiser.enabledKey)
            if let stamp { d.set(stamp, forKey: MusicVisualiser.stampKey) }
            var made = 0
            let v = MusicVisualiser(defaults: d, identity: Self.build, makeTap: { made += 1; return FakeTap() })
            XCTAssertFalse(v.enabled, "\(String(describing: stamp))")
            XCTAssertTrue(v.needsReenable)
            XCTAssertFalse(d.bool(forKey: MusicVisualiser.enabledKey), "saved off")
            v.setWidgetRunning(true)
            v.setPlaying(true)
            v.setViewer(UUID(), visible: true)
            XCTAssertEqual(made, 0, "no tap (no prompt) on play after an update")

            v.setEnabled(true)   // "Turn On Again": the prompt belongs to this action
            XCTAssertFalse(v.needsReenable)
            XCTAssertEqual(made, 1)
            XCTAssertEqual(d.string(forKey: MusicVisualiser.stampKey), Self.build)
            v.setWidgetRunning(false)
        }
    }

    func testSameBuildKeepsTheToggle() {
        let (v, taps, _) = make(enabled: true)
        XCTAssertTrue(v.enabled)
        XCTAssertFalse(v.needsReenable)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        XCTAssertEqual(taps().count, 1)
    }

    func testGrantHolds() {
        XCTAssertTrue(CodeIdentity.grantHolds("dr:x", current: "dr:x"))
        XCTAssertFalse(CodeIdentity.grantHolds("dr:x", current: "dr:y"))
        XCTAssertFalse(CodeIdentity.grantHolds(nil, current: "dr:x"))
        XCTAssertFalse(CodeIdentity.grantHolds("", current: ""))
    }

    func testNoPrimeWhileWidgetOff() {
        let (v, taps, _) = make()
        v.setEnabled(true)   // only reachable from Settings while the widget runs; still safe
        XCTAssertTrue(taps().isEmpty)
    }

    func testFailedTapStaysSynthetic() {
        let d = defaults()
        d.set(true, forKey: MusicVisualiser.enabledKey)
        d.set(Self.build, forKey: MusicVisualiser.stampKey)
        let v = MusicVisualiser(defaults: d, identity: Self.build,
                                makeTap: { let t = FakeTap(); t.fail = true; return t })
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        XCTAssertFalse(v.isRunning)
        XCTAssertFalse(v.hasSignal)
    }

    /// Samples become levels; silence (or a denied permission) means no signal, and the
    /// bars fall back to the synthetic animation.
    func testSignalAndSilence() {
        let (v, taps, _) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        let t0 = Date()
        taps()[0].deliver([Float](repeating: 0, count: 1024))
        XCTAssertEqual(v.frame(now: t0), MusicVisualiser.quietRate)
        XCTAssertFalse(v.hasSignal)
        let tone = (0..<1024).map { Float(0.8 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        taps()[0].deliver(tone)
        XCTAssertEqual(v.frame(now: t0), MusicVisualiser.frameRate)
        XCTAssertTrue(v.hasSignal)
        XCTAssertGreaterThan(v.levels.max() ?? 0, 0.3)
        taps()[0].deliver([Float](repeating: 0, count: 1024))
        v.frame(now: t0.addingTimeInterval(MusicVisualiser.silenceGrace + 0.1))
        XCTAssertFalse(v.hasSignal)
    }

    func testGroupBands() {
        XCTAssertEqual(MusicVisualiser.group([1, 1, 0, 0, 0.5, 0.5], into: 3), [1, 0, 0.5])
        XCTAssertEqual(MusicVisualiser.group([1, 0], into: 3).count, 3)
        XCTAssertEqual(MusicVisualiser.group([], into: 3), [])
    }

    func testMusicBarsLiveHeights() {
        let h = MusicBars.heights(levels: [0, 1, 2, -1], height: 10)
        XCTAssertEqual(h, [2, 10, 10, 2])
        XCTAssertEqual(MusicBars.heights(at: nil, count: 6, height: 20).count, 6)
    }

    /// The perf hook: a fake track plays, no player is read.
    func testFakePlayingReportsATrack() {
        let np = NowPlaying()
        np.fakePlaying = true
        np.start()
        XCTAssertTrue(np.isPlaying)
        XCTAssertEqual(np.source, .none, "no adapter, no AppleScript")
        np.stop()
        XCTAssertFalse(np.isPlaying)
    }

    /// The synthetic loop is the same sine `heights(at:)` draws, over one period per bar.
    func testSyntheticLoopMatchesTheSine() {
        for bar in 0..<3 {
            let loop = MusicBars.syntheticLoop(bar: bar, height: 10, samples: 24)
            XCTAssertEqual(loop.heights.count, 25)
            XCTAssertEqual(loop.heights.first ?? 0, loop.heights.last ?? 1, accuracy: 1e-9, "loops seamlessly")
            for (k, h) in loop.heights.enumerated() {
                let t = loop.duration * Double(k) / 24
                XCTAssertEqual(h, MusicBars.heights(at: t, count: 3, height: 10)[bar], accuracy: 1e-9)
            }
        }
    }

    /// Still: fixed heights, no animation. Synthetic: Core Animation bounces the bars (no
    /// SwiftUI timeline). Live: the layers follow the levels.
    func testBarLayersFollowTheMode() {
        let view = MusicBarsNSView(frame: NSRect(x: 0, y: 0, width: 12, height: 10))
        let style = MusicBarsNSView.Style(color: .systemGreen, count: 3, height: 10, barWidth: 2.5, spacing: 2)
        view.configure(style: style, mode: .still, visualiser: nil)
        XCTAssertFalse(view.isBouncing)
        XCTAssertEqual(view.barHeights, MusicBars.heights(at: nil, count: 3, height: 10))
        view.configure(style: style, mode: .synthetic, visualiser: nil)
        XCTAssertTrue(view.isBouncing)
        let (v, _, _) = make(enabled: true)
        view.configure(style: style, mode: .live, visualiser: v)
        XCTAssertFalse(view.isBouncing)
        XCTAssertEqual(view.barHeights, MusicBars.heights(levels: [0, 0, 0], height: 10), "silent levels: stubs")
        view.configure(style: style, mode: .still, visualiser: nil)
        XCTAssertFalse(view.isBouncing)
    }

    /// The widget wires the visualiser to playback and to its own start / stop.
    func testWidgetFeedsVisualiser() {
        let (v, taps, _) = make(enabled: true)
        let np = NowPlaying()
        let w = MusicWidget(nowPlaying: np, visualiser: v)
        XCTAssertNotNil(w.settingsView(), "the visualiser toggle lives in the widget's settings")
        w.stop()
        XCTAssertTrue(taps().isEmpty)
        XCTAssertNil(np.onPlayingChange)
    }

    /// The sink copies under the lock and analyses outside it; clearing forgets everything.
    func testSinkLevelsAndClear() {
        let sink = SampleSink(bands: 4)
        let tone = (0..<1024).map { Float(0.8 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        tone.withUnsafeBufferPointer { sink.push($0, channels: 1, sampleRate: 48_000) }
        XCTAssertEqual(sink.retainedSampleCount, 1024)
        XCTAssertGreaterThan(sink.levels().values.max() ?? 0, 0.7)
        sink.clear()
        XCTAssertEqual(sink.retainedSampleCount, 0)
        XCTAssertEqual(sink.levels().values, [0, 0, 0, 0])
    }

    /// A report with no timestamp is stamped when it arrives, not on each read; a later
    /// report with the same elapsed time keeps that stamp.
    func testClockStampedOnceOnArrival() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let report = NowPlayingInfo(bundleIdentifier: "x", title: "T", isPlaying: true, elapsed: 10, duration: 100)
        let first = NowPlaying.stamped(report, previous: nil, now: t0)
        XCTAssertEqual(first?.timestamp, t0)
        let clock = PlaybackClock(info: first!, now: t0.addingTimeInterval(5))
        XCTAssertEqual(clock?.position(now: t0.addingTimeInterval(5)), 15, "moves on from the stamp")
        var diff = report
        diff.artist = "New"
        XCTAssertEqual(NowPlaying.stamped(diff, previous: first, now: t0.addingTimeInterval(9))?.timestamp, t0)
        var moved = report
        moved.elapsed = 50
        XCTAssertEqual(NowPlaying.stamped(moved, previous: first, now: t0.addingTimeInterval(9))?.timestamp,
                       t0.addingTimeInterval(9))
        // C6: same elapsed but paused, another track or another player: a fresh stamp.
        let later = t0.addingTimeInterval(9)
        var paused = report
        paused.isPlaying = false
        XCTAssertEqual(NowPlaying.stamped(paused, previous: first, now: later)?.timestamp, later)
        var other = report
        other.title = "Other"
        XCTAssertEqual(NowPlaying.stamped(other, previous: first, now: later)?.timestamp, later)
        var player = report
        player.bundleIdentifier = "y"
        XCTAssertEqual(NowPlaying.stamped(player, previous: first, now: later)?.timestamp, later)
        let given = NowPlayingInfo(bundleIdentifier: "x", title: "T", isPlaying: true, elapsed: 1, timestamp: t0)
        XCTAssertEqual(NowPlaying.stamped(given, previous: nil, now: t0.addingTimeInterval(3))?.timestamp, t0)
        XCTAssertNil(NowPlaying.stamped(NowPlayingInfo(bundleIdentifier: "x", title: "T", isPlaying: true),
                                        previous: nil, now: t0)?.timestamp, "no elapsed: nothing to stamp")
    }

    func testSeekWithoutTimesDoesNothing() {
        let np = NowPlaying()
        np.seek(to: 10)   // nothing playing, not started: no crash, no command
        XCTAssertNil(np.clock)
    }
}
