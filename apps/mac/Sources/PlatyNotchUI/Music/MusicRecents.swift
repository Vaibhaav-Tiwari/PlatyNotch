import Foundation
import PlatyNotchKit

/// Recent things to play in the last app, for the Now Playing card's empty state.
protocol MusicRecentsProviding: Sendable {
    func recents(for bundleID: String) async -> [String]
}

/// Apple Music only (Island spec 3.5): its first user playlists by name, read through the
/// existing Automation path and only when Automation is already granted (checked without
/// asking) and Music is running (never launched). Spotify and others: none.
struct MusicAppRecents: MusicRecentsProviding {
    let automationGranted: @Sendable () -> Bool

    init(automationGranted: @escaping @Sendable () -> Bool) {
        self.automationGranted = automationGranted
    }

    static let system = MusicAppRecents {
        Permissions.automationStatus(bundleID: AppleScriptPlayer.music.rawValue, ask: false) == .granted
    }

    static let script = """
    if application id "com.apple.Music" is not running then return ""
    with timeout of 2 seconds
        tell application id "com.apple.Music"
            set names to name of (user playlists whose special kind is none)
        end tell
    end timeout
    set out to ""
    set n to 0
    repeat with x in names
        if n is 2 then exit repeat
        set out to out & x & (character id 31)
        set n to n + 1
    end repeat
    return out
    """

    func recents(for bundleID: String) async -> [String] {
        guard bundleID == AppleScriptPlayer.music.rawValue else { return [] }
        let granted = automationGranted
        return await withCheckedContinuation { (c: CheckedContinuation<[String], Never>) in
            AppleScriptPlayer.queue.async {
                guard granted(), AppleScriptPlayer.music.isRunning,
                      let out = AppleScriptPlayer.execute(Self.script) else { c.resume(returning: []); return }
                let names = out.components(separatedBy: NowPlayingInfo.appleScriptSeparator)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                c.resume(returning: Array(names.prefix(MusicEmptyState.maxRecents)))
            }
        }
    }
}

/// Never reads anything (renders, smoke runs).
struct NoRecents: MusicRecentsProviding {
    func recents(for bundleID: String) async -> [String] { [] }
}
