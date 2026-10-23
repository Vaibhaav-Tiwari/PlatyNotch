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

    public init(bundleIdentifier: String, title: String, artist: String? = nil, album: String? = nil,
                isPlaying: Bool, artwork: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier; self.title = title; self.artist = artist
        self.album = album; self.isPlaying = isPlaying; self.artwork = artwork
    }

    /// Field separator in the AppleScript fallback's output (ASCII unit separator).
    public static let appleScriptSeparator = "\u{1F}"

    /// Parses the fallback script's `bundleID␟state␟title␟artist` ("playing" / "paused";
    /// anything else, or no title, is nothing playing).
    public static func parseAppleScript(_ output: String) -> NowPlayingInfo? {
        let parts = output.components(separatedBy: appleScriptSeparator)
        guard parts.count == 4, !parts[0].isEmpty, !parts[2].isEmpty else { return nil }
        let playing: Bool
        switch parts[1] {
        case "playing": playing = true
        case "paused": playing = false
        default: return nil
        }
        return NowPlayingInfo(bundleIdentifier: parts[0], title: parts[2],
                              artist: parts[3].isEmpty ? nil : parts[3], isPlaying: playing)
    }
}

/// Folds mediaremote-adapter `stream` output (one JSON object per line:
/// `{"type":"data","diff":Bool,"payload":{...}}`) into the current `NowPlayingInfo`.
/// A non-diff payload replaces the state; a diff payload updates only its keys, and a
/// `null` value removes that key. An empty payload means nothing is playing.
public struct MediaRemoteStreamParser: Sendable {
    private var bundleIdentifier: String?
    private var title: String?
    private var artist: String?
    private var album: String?
    private var playing: Bool?
    private var artwork: Data?

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
        string("bundleIdentifier", &bundleIdentifier)
        string("title", &title)
        string("artist", &artist)
        string("album", &album)
        if let v = p["playing"] { playing = (v as? NSNumber)?.boolValue }
        if let v = p["artworkData"] { artwork = (v as? String).flatMap { Data(base64Encoded: $0) } }
    }

    public var current: NowPlayingInfo? {
        guard let bundleIdentifier, let title, !title.isEmpty else { return nil }
        return NowPlayingInfo(bundleIdentifier: bundleIdentifier, title: title,
                              artist: artist?.isEmpty == false ? artist : nil,
                              album: album?.isEmpty == false ? album : nil,
                              isPlaying: playing ?? false, artwork: artwork)
    }
}
