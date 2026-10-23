import Foundation
import Observation
import os
import PlatyNotchKit
import SwiftUI

/// The live visualiser: band levels from what the Mac is playing, for `MusicBars`.
///
/// Off by default (Settings › Widgets › Music › "Live visualiser"). The audio tap runs only
/// while all of these hold: the toggle is on, the music widget runs, music plays, and a
/// pill or tile with bars is on screen (each `MusicBars` reports itself, and only while the
/// panel is really shown and Reduce Motion is off). Anything else stops and destroys the
/// tap at once. The one exception is turning the toggle on: the tap starts for
/// `primeDuration` so macOS asks for System Audio Recording then, never on a later play.
///
/// Privacy: samples go from the tap into `SpectrumAnalyser` (one FFT window, in memory,
/// overwritten) and leave it only as band levels; nothing is written or sent.
///
/// Cost: with the toggle off nothing here runs (the bars keep their 12 fps idle
/// animation). While the tap runs, levels update at most `frameRate` times a second, and at
/// `quietRate` while no signal arrives (silence, or permission denied).
@MainActor @Observable
public final class MusicVisualiser {
    public static let enabledKey = "music.visualiser"
    public static let bandCount = 12
    public static let frameRate = 30.0
    public static let quietRate = 4.0
    /// Below this (0…1) every band counts as silence.
    public static let signalFloor: Float = 0.02
    /// No signal for this long → the bars fall back to their synthetic animation.
    public static let silenceGrace: TimeInterval = 1.5

    /// Smoothed levels, `bandCount` of them (0 while stopped).
    public private(set) var levels: [Float] = Array(repeating: 0, count: MusicVisualiser.bandCount)
    /// Real audio is arriving: the bars follow `levels` (else the synthetic animation).
    public private(set) var hasSignal = false
    /// The tap exists and runs.
    public private(set) var isRunning = false
    /// The user's toggle (persisted).
    public private(set) var enabled: Bool

    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "Visualiser")
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeTap: @MainActor () -> AudioTapping
    @ObservationIgnored private let primeDuration: TimeInterval
    @ObservationIgnored private var tap: AudioTapping?
    @ObservationIgnored private let sink = SampleSink(bands: MusicVisualiser.bandCount)
    @ObservationIgnored private var smoother = BarSmoother(bands: MusicVisualiser.bandCount)
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var primeTask: Task<Void, Never>?
    @ObservationIgnored private var priming = false
    @ObservationIgnored private var lastSignal: Date?
    @ObservationIgnored private var playing = false
    @ObservationIgnored private var widgetRunning = false
    @ObservationIgnored private var viewers: Set<UUID> = []

    public init(defaults: UserDefaults = .standard, primeDuration: TimeInterval = 2,
                makeTap: @escaping @MainActor () -> AudioTapping = { SystemAudioTap() }) {
        self.defaults = defaults
        self.primeDuration = primeDuration
        self.makeTap = makeTap
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// The tap would run now (exposed for tests).
    var wantsTap: Bool {
        enabled && widgetRunning && (priming || (playing && !viewers.isEmpty))
    }

    // MARK: - Inputs

    /// The user flipped the toggle. Turning it on starts the tap briefly so the permission
    /// prompt (first time only) belongs to this action.
    public func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        primeTask?.cancel()
        primeTask = nil
        priming = false
        if on, widgetRunning {
            priming = true
            let d = primeDuration
            primeTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(d))
                guard let self, !Task.isCancelled else { return }
                self.priming = false
                self.primeTask = nil
                self.reconcile()
            }
        }
        reconcile()
    }

    public func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        reconcile()
    }

    /// The music widget started or stopped (disabled widgets do no work).
    public func setWidgetRunning(_ on: Bool) {
        widgetRunning = on
        if !on {
            primeTask?.cancel()
            primeTask = nil
            priming = false
        }
        reconcile()
    }

    /// A bars view is on screen (and animating) or not.
    public func setViewer(_ id: UUID, visible: Bool) {
        let changed = visible ? viewers.insert(id).inserted : viewers.remove(id) != nil
        if changed { reconcile() }
    }

    // MARK: - Tap

    private func reconcile() {
        if wantsTap, tap == nil {
            startTap()
        } else if !wantsTap, tap != nil {
            stopTap()
        }
    }

    private func startTap() {
        let t = makeTap()
        let sink = self.sink
        do {
            try t.start { samples, channels, rate in sink.push(samples, channels: channels, sampleRate: rate) }
        } catch {
            Self.log.error("visualiser tap failed: \(String(describing: error), privacy: .public)")
            t.stop()
            return   // bars stay synthetic; the next change of inputs tries again
        }
        tap = t
        isRunning = true
        lastSignal = nil
        smoother.reset()
        frameTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let rate = self.frame(now: Date())
                try? await Task.sleep(for: .seconds(1 / rate))
            }
        }
    }

    private func stopTap() {
        frameTask?.cancel()
        frameTask = nil
        tap?.stop()
        tap = nil
        sink.clear()
        smoother.reset()
        isRunning = false
        hasSignal = false
        lastSignal = nil
        levels = Array(repeating: 0, count: Self.bandCount)
    }

    /// One update; returns the rate for the next.
    @discardableResult
    func frame(now: Date) -> Double {
        let raw = sink.levels().values
        if raw.contains(where: { $0 > Self.signalFloor }) { lastSignal = now }
        let signal = lastSignal.map { now.timeIntervalSince($0) < Self.silenceGrace } ?? false
        if signal != hasSignal { hasSignal = signal }
        let next = smoother.push(raw)
        if signal, next != levels { levels = next }
        return signal ? Self.frameRate : Self.quietRate
    }

    /// `levels` grouped into `count` bars (means of equal runs of bands).
    public static func group(_ levels: [Float], into count: Int) -> [Float] {
        guard count > 0, !levels.isEmpty else { return [] }
        return (0..<count).map { i in
            let lo = i * levels.count / count, hi = max(lo + 1, (i + 1) * levels.count / count)
            let run = levels[lo..<min(hi, levels.count)]
            return run.reduce(0, +) / Float(run.count)
        }
    }
}

/// The analyser behind a lock: the tap's thread pushes, the main actor reads levels.
final class SampleSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var analyser: SpectrumAnalyser

    init(bands: Int) { analyser = SpectrumAnalyser(bands: bands) }

    func push(_ samples: UnsafeBufferPointer<Float>, channels: Int, sampleRate: Double) {
        lock.withLockUnchecked { analyser.push(interleaved: samples, channels: channels, sampleRate: sampleRate) }
    }

    func levels() -> BandLevels { lock.withLockUnchecked { analyser.levels() } }
    func clear() { lock.withLockUnchecked { analyser.clear() } }
    var retainedSampleCount: Int { lock.withLockUnchecked { analyser.retainedSampleCount } }
}

extension EnvironmentValues {
    /// The live visualiser the music bars follow (nil: synthetic animation only).
    @Entry var musicVisualiser: MusicVisualiser? = nil
}
