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

@MainActor
final class MusicVisualiserTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "dev.platynotch.tests.visualiser.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func make(enabled: Bool = false, prime: TimeInterval = 0.05) -> (MusicVisualiser, () -> [FakeTap], UserDefaults) {
        let d = defaults()
        d.set(enabled, forKey: MusicVisualiser.enabledKey)
        var taps: [FakeTap] = []
        let v = MusicVisualiser(defaults: d, primeDuration: prime, makeTap: {
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
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(v.isRunning, "nothing playing or visible: the tap stops after priming")
        XCTAssertEqual(taps()[0].stops, 1)
    }

    func testRunsOnlyWhilePlayingAndVisible() {
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
        XCTAssertFalse(v.isRunning, "neither the pill nor the tile is visible: the tap stops")
        XCTAssertEqual(taps()[0].stops, 1)
        v.setViewer(tile, visible: true)
        XCTAssertEqual(taps().count, 2, "a fresh tap when bars show again")
        v.setPlaying(false)
        XCTAssertFalse(v.isRunning, "paused: the tap stops")
    }

    func testTogglingOffStopsAtOnce() {
        let (v, taps, d) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        XCTAssertTrue(v.isRunning)
        v.setEnabled(false)
        XCTAssertFalse(v.isRunning)
        XCTAssertEqual(taps()[0].stops, 1)
        XCTAssertFalse(d.bool(forKey: MusicVisualiser.enabledKey))
        XCTAssertEqual(v.levels, Array(repeating: 0, count: MusicVisualiser.bandCount))
    }

    func testWidgetStopStopsTheTap() {
        let (v, taps, _) = make(enabled: true)
        v.setWidgetRunning(true)
        v.setPlaying(true)
        v.setViewer(UUID(), visible: true)
        v.setWidgetRunning(false)
        XCTAssertFalse(v.isRunning)
        XCTAssertEqual(taps()[0].stops, 1)
    }

    func testNoPrimeWhileWidgetOff() {
        let (v, taps, _) = make()
        v.setEnabled(true)   // only reachable from Settings while the widget runs; still safe
        XCTAssertTrue(taps().isEmpty)
    }

    func testFailedTapStaysSynthetic() {
        let d = defaults()
        d.set(true, forKey: MusicVisualiser.enabledKey)
        let v = MusicVisualiser(defaults: d, makeTap: { let t = FakeTap(); t.fail = true; return t })
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

    func testSeekWithoutTimesDoesNothing() {
        let np = NowPlaying()
        np.seek(to: 10)   // nothing playing, not started: no crash, no command
        XCTAssertNil(np.clock)
    }
}
