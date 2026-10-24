import Foundation

/// What is playing, from the MediaRemote adapter or the AppleScript fallback.
public struct NowPlayingInfo: Equatable, Sendable {
    public var bundleIdentifier: String
    public var title: String
    public var artist: String?
    public var album: String?
    public var isPlaying: Bool
    /// Encoded image bytes (JPEG/PNG), adapter only.
    public var artwork: Data?
    /// Seconds into the track at `timestamp` (nil when the player does not say).
    public var elapsed: TimeInterval?
    /// Track length in seconds (nil when unknown, e.g. a live stream).
    public var duration: TimeInterval?
    /// Playback speed the player reported (1 normal, 0 paused).
    public var rate: Double?
    /// When `elapsed` was measured.
    public var timestamp: Date?
    /// The app behind a helper process (Safari for `com.apple.WebKit.GPU`), adapter only.
    public var parentBundleIdentifier: String?

    public init(bundleIdentifier: String, title: String, artist: String? = nil, album: String? = nil,
                isPlaying: Bool, artwork: Data? = nil, elapsed: TimeInterval? = nil, duration: TimeInterval? = nil,
                rate: Double? = nil, timestamp: Date? = nil, parentBundleIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier; self.title = title; self.artist = artist
        self.album = album; self.isPlaying = isPlaying; self.artwork = artwork
        self.elapsed = elapsed; self.duration = duration; self.rate = rate; self.timestamp = timestamp
        self.parentBundleIdentifier = parentBundleIdentifier
    }

    /// The app to show (its icon and name): the parent app when a helper reports.
    public var appBundleIdentifier: String { parentBundleIdentifier ?? bundleIdentifier }

    /// Field separator in the AppleScript fallback's output (ASCII unit separator).
    public static let appleScriptSeparator = "\u{1F}"

    /// Parses the fallback script's `bundleID␟state␟title␟artist[␟positionMs␟durationMs]`
    /// ("playing" / "paused"; anything else, or no title, is nothing playing). Times are
    /// integer milliseconds (locale-proof); an unreadable time is nil. `now` stamps them.
    public static func parseAppleScript(_ output: String, now: Date = Date()) -> NowPlayingInfo? {
        let parts = output.components(separatedBy: appleScriptSeparator)
        guard parts.count == 4 || parts.count == 6, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
        let playing: Bool
        switch parts[1] {
        case "playing": playing = true
        case "paused": playing = false
        default: return nil
        }
        var info = NowPlayingInfo(bundleIdentifier: parts[0], title: parts[2],
                                  artist: parts[3].isEmpty ? nil : parts[3], isPlaying: playing)
        if parts.count == 6 {
            func seconds(_ s: String) -> TimeInterval? { Double(s).flatMap { $0 >= 0 ? $0 / 1000 : nil } }
            info.elapsed = seconds(parts[4])
            info.duration = seconds(parts[5]).flatMap { $0 > 0 ? $0 : nil }
            if info.elapsed != nil {
                info.rate = playing ? 1 : 0
                info.timestamp = now
            }
        }
        return info
    }
}

/// Folds mediaremote-adapter `stream` output (one JSON object per line:
/// `{"type":"data","diff":Bool,"payload":{...}}`) into the current `NowPlayingInfo`.
/// A non-diff payload replaces the state; a diff payload updates only its keys, and a
/// `null` value removes that key. An empty payload means nothing is playing.
///
/// Times (v0.7.7): with `--micros` `elapsedTimeMicros`, `durationMicros` and
/// `timestampEpochMicros` (microseconds; the timestamp since 1970); without it
/// `elapsedTime` and `duration` in seconds and `timestamp` as `yyyy-MM-ddTHH:mm:ssZ`.
/// `playbackRate` is a number either way.
public struct MediaRemoteStreamParser: Sendable {
    private var bundleIdentifier: String?
    private var parentBundleIdentifier: String?
    private var title: String?
    private var artist: String?
    private var album: String?
    private var playing: Bool?
    private var artwork: Data?
    private var elapsed: TimeInterval?
    private var duration: TimeInterval?
    private var rate: Double?
    private var timestamp: Date?

    public init() {}

    /// Applies one line. Returns false (state unchanged) for anything but a data update;
    /// read the result from `current` (nil when nothing is playing).
    @discardableResult
    public mutating func feed(_ line: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "data",
              let payload = obj["payload"] as? [String: Any] else { return false }
        if (obj["diff"] as? Bool) != true { self = MediaRemoteStreamParser() }
        apply(payload)
        return true
    }

    private mutating func apply(_ p: [String: Any]) {
        func string(_ key: String, _ field: inout String?) {
            guard let v = p[key] else { return }
            field = v as? String
        }
        func number(_ key: String, scale: Double, _ field: inout Double?) {
            guard let v = p[key] else { return }
            field = (v as? NSNumber).map { $0.doubleValue * scale }
        }
        string("bundleIdentifier", &bundleIdentifier)
        string("parentApplicationBundleIdentifier", &parentBundleIdentifier)
        string("title", &title)
        string("artist", &artist)
        string("album", &album)
        if let v = p["playing"] { playing = (v as? NSNumber)?.boolValue }
        if let v = p["artworkData"] { artwork = (v as? String).flatMap { Data(base64Encoded: $0) } }
        number("elapsedTime", scale: 1, &elapsed)
        number("elapsedTimeMicros", scale: 1e-6, &elapsed)
        number("duration", scale: 1, &duration)
        number("durationMicros", scale: 1e-6, &duration)
        number("playbackRate", scale: 1, &rate)
        if let v = p["timestampEpochMicros"] {
            timestamp = (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1e6) }
        }
        if let v = p["timestamp"] {
            timestamp = (v as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        }
    }

    public var current: NowPlayingInfo? {
        guard let bundleIdentifier, let title, !title.isEmpty else { return nil }
        return NowPlayingInfo(bundleIdentifier: bundleIdentifier, title: title,
                              artist: artist?.isEmpty == false ? artist : nil,
                              album: album?.isEmpty == false ? album : nil,
                              isPlaying: playing ?? false, artwork: artwork,
                              elapsed: elapsed, duration: duration.flatMap { $0 > 0 ? $0 : nil },
                              rate: rate, timestamp: timestamp,
                              parentBundleIdentifier: parentBundleIdentifier?.isEmpty == false ? parentBundleIdentifier : nil)
    }
}
