import Foundation

/// Where playback is, between the player's updates: `elapsed` at `at`, moving at `rate`
/// (0 paused, 1 normal). Players report only on changes (play, pause, seek, track), so the
/// scrubber extrapolates from the last report.
public struct PlaybackClock: Equatable, Sendable {
    public var elapsed: TimeInterval
    /// 0 when unknown (a live stream): the position is then not clamped above.
    public var duration: TimeInterval
    public var rate: Double
    public var at: Date

    public init(elapsed: TimeInterval, duration: TimeInterval, rate: Double, at: Date) {
        self.elapsed = elapsed
        self.duration = duration
        self.rate = rate
        self.at = at
    }

    /// From a now-playing report: nil without an elapsed time. A paused player's rate is
    /// 0 whatever it said; a playing one with no rate moves at 1. No timestamp means "now".
    public init?(info: NowPlayingInfo, now: Date) {
        guard let elapsed = info.elapsed else { return nil }
        let rate = info.isPlaying ? (info.rate.flatMap { $0 > 0 ? $0 : nil } ?? 1) : 0
        self.init(elapsed: elapsed, duration: max(info.duration ?? 0, 0), rate: rate, at: info.timestamp ?? now)
    }

    /// Seconds into the track at `now`, between 0 and `duration` (when known).
    public func position(now: Date) -> TimeInterval {
        let p = max(0, elapsed + now.timeIntervalSince(at) * rate)
        return duration > 0 ? min(p, duration) : p
    }

    /// 0…1 through the track; 0 when the length is unknown.
    public func progress(now: Date) -> Double {
        duration > 0 ? position(now: now) / duration : 0
    }

    public func remaining(now: Date) -> TimeInterval {
        duration > 0 ? duration - position(now: now) : 0
    }

    /// The clock after a seek to `position` at `now` (clamped), at the same rate.
    public func seeking(to position: TimeInterval, at now: Date) -> PlaybackClock {
        let p = duration > 0 ? min(max(position, 0), duration) : max(position, 0)
        return PlaybackClock(elapsed: p, duration: duration, rate: rate, at: now)
    }
}
