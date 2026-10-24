import AppKit
import ImageIO
import Observation
import PlatyNotchKit
import SwiftUI
import os

/// What is playing system-wide. Reads mediaremote-adapter's `stream` (run with /usr/bin/perl,
/// which may use MediaRemote on macOS 15.4+); if the adapter is missing or will not start,
/// falls back to AppleScript polling of Spotify and Music: every 2 s while the tile is on
/// screen or music plays, else every 6 s and only for players whose Automation permission
/// is already granted (so the pill sees music start without ever prompting at launch).
///
/// The adapter (BSD-3-Clause) is not in the repo: `scripts/fetch-mediaremote-adapter.sh` builds
/// it into `Contents/Resources/mediaremote-adapter/` (or set `PLATYNOTCH_MEDIAREMOTE_DIR`).
@MainActor @Observable
public final class NowPlaying {
    public enum Source: Equatable { case none, adapter, appleScript }

    public private(set) var info: NowPlayingInfo?
    public private(set) var artwork: NSImage?
    public private(set) var source: Source = .none
    /// The artwork's dominant colour (the tile's glow), worked out off the main thread once
    /// per artwork; nil without artwork or until it is ready.
    public private(set) var artworkTint: Color?
    /// The playing app's icon and name (Safari for a web player), looked up once per app.
    public private(set) var appIcon: NSImage?
    public private(set) var appName: String?
    /// The default output device's name, read while the tile is on screen.
    public private(set) var outputDevice: String?
    /// Music's favourite state after the user toggled it (nil: not known).
    public private(set) var liked: Bool?

    public var title: String? { info?.title }
    public var artist: String? { info?.artist }
    public var isPlaying: Bool { info?.isPlaying ?? false }
    /// Where playback is (nil when the player gives no times).
    public var clock: PlaybackClock? { info.flatMap { PlaybackClock(info: $0, now: Date()) } }
    /// Favourites work for Apple Music only (Spotify has no AppleScript for it).
    public var canLike: Bool { info?.bundleIdentifier == AppleScriptPlayer.music.rawValue }
    /// Called when `isPlaying` changes (the visualiser follows it).
    @ObservationIgnored public var onPlayingChange: ((Bool) -> Void)?

    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch", category: "NowPlaying")
    @ObservationIgnored private var adapter: AdapterStream?
    @ObservationIgnored private var adapterRestarts = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var started = false
    /// Fallback ticks since the last idle poll (idle polls run every `idlePollTicks`).
    @ObservationIgnored private var idleTicks = 0
    @ObservationIgnored private var artworkGeneration = 0
    static let idlePollTicks = 3

    public init() {}

    /// Starts reading (idempotent). Called by the music widget when it starts (at launch
    /// when the widget is enabled).
    public func start() {
        guard !started else { return }
        started = true
        if let files = AdapterFiles.locate() {
            startAdapter(files)
        } else {
            Self.log.notice("mediaremote-adapter not bundled; using AppleScript for Spotify / Music")
            startFallback()
        }
    }

    public func stop() {
        started = false
        adapter?.stop()
        adapter = nil
        pollTask?.cancel()
        pollTask = nil
        source = .none
        apply(nil)   // a stopped reader shows nothing (and the pill drops the music bars)
    }

    /// The music tile reports when it is on screen; the AppleScript fallback polls every 2 s
    /// only then (or while music was playing at the last poll), else at the idle rate.
    public func setVisible(_ visible: Bool) {
        viewers = max(0, viewers + (visible ? 1 : -1))
        if visible { refreshOutputDevice() }
    }

    public func playPause() { command(.togglePlayPause) }
    public func next() { command(.next) }
    public func previous() { command(.previous) }

    /// Seeks to `seconds` into the track: the adapter's `seek` (microseconds), else
    /// AppleScript `player position`. The scrubber moves at once; the player's next report
    /// confirms it.
    public func seek(to seconds: TimeInterval) {
        guard var current = info, let clock else { return }
        let target = clock.seeking(to: seconds, at: Date())
        switch source {
        case .adapter:
            guard let files = AdapterFiles.locate() else { return }
            AdapterStream.send(files: files, arguments: ["seek", String(Int64(target.elapsed * 1_000_000))])
        case .appleScript:
            guard let player = AppleScriptPlayer(rawValue: current.bundleIdentifier), player.isRunning else { return }
            let position = target.elapsed
            AppleScriptPlayer.queue.async { player.seek(to: position) }
        case .none:
            return
        }
        current.elapsed = target.elapsed
        current.timestamp = target.at
        apply(current)
    }

    /// Toggles the current track's favourite in Apple Music (asks for Automation the
    /// first time, on this click).
    public func toggleLike() {
        guard canLike, AppleScriptPlayer.music.isRunning else { return }
        let title = info?.title
        AppleScriptPlayer.queue.async {
            let result = AppleScriptPlayer.music.toggleFavourite()
            Task { @MainActor [weak self] in
                guard let self, self.info?.title == title else { return }
                self.liked = result
            }
        }
    }

    // MARK: - Adapter

    private func startAdapter(_ files: AdapterFiles) {
        let stream = AdapterStream(files: files,
            onUpdate: { [weak self] info in Task { @MainActor in self?.update(info) } },
            onExit: { [weak self] receivedAny, status in
                Task { @MainActor in self?.adapterExited(receivedAny: receivedAny, status: status) }
            })
        do {
            try stream.start()
            adapter = stream
            source = .adapter
        } catch {
            Self.log.error("mediaremote-adapter failed to start: \(error.localizedDescription, privacy: .public)")
            startFallback()
        }
    }

    private func adapterExited(receivedAny: Bool, status: Int32) {
        guard started, source == .adapter else { return }
        adapter = nil
        Self.log.error("mediaremote-adapter exited (\(status)); output seen: \(receivedAny)")
        // An adapter that never produced output does not work on this macOS: fall back.
        guard receivedAny, adapterRestarts < 3, let files = AdapterFiles.locate() else {
            update(nil)
            startFallback()
            return
        }
        adapterRestarts += 1
        let delay = Double(adapterRestarts) * 2
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.started, self.adapter == nil, self.source == .adapter else { return }
            self.startAdapter(files)
        }
    }

    /// Results from the adapter or a poll. Ignored once stopped: an adapter line or an
    /// AppleScript poll still in flight at `stop` must not bring the music back.
    func update(_ new: NowPlayingInfo?) {
        guard started else { return }
        apply(new)
    }

    private func apply(_ new: NowPlayingInfo?, now: Date = Date()) {
        let new = Self.stamped(new, previous: info, now: now)
        guard new != info else { return }
        let wasPlaying = isPlaying
        if new?.artwork != info?.artwork {
            artwork = new?.artwork.flatMap { NSImage(data: $0) }
            tintArtwork(new?.artwork)
        }
        if new?.appBundleIdentifier != info?.appBundleIdentifier { lookUpApp(new?.appBundleIdentifier) }
        if new?.title != info?.title || new?.bundleIdentifier != info?.bundleIdentifier { liked = nil }
        info = new
        if isPlaying != wasPlaying { onPlayingChange?(isPlaying) }
        if viewers > 0 { refreshOutputDevice() }
    }

    /// A report with an elapsed time but no timestamp is stamped once, when it arrives (so
    /// `clock` does not restart from `elapsed` on every read). An unchanged elapsed time
    /// keeps the earlier stamp: a diff about something else does not move the clock.
    static func stamped(_ new: NowPlayingInfo?, previous: NowPlayingInfo?, now: Date) -> NowPlayingInfo? {
        guard var new, new.elapsed != nil, new.timestamp == nil else { return new }
        if let previous, previous.elapsed == new.elapsed, let at = previous.timestamp {
            new.timestamp = at
        } else {
            new.timestamp = now
        }
        return new
    }

    /// The glow colour, off the main thread; a newer artwork wins over a late result.
    private func tintArtwork(_ data: Data?) {
        artworkGeneration += 1
        artworkTint = nil
        guard let data else { return }
        let generation = artworkGeneration
        // The decode runs detached and never sees `self`; the result is applied back here
        // on the main actor (older compilers reject sending `self` into the detached task).
        Task { [weak self] in
            let rgb = await Task.detached(priority: .utility) { NowPlaying.dominantColor(of: data) }.value
            guard let self, let rgb, self.artworkGeneration == generation else { return }
            self.artworkTint = Color(red: rgb.r, green: rgb.g, blue: rgb.b)
        }
    }

    /// A small thumbnail (no full decode) through `DominantColor`.
    nonisolated static func dominantColor(of data: Data) -> (r: Double, g: Double, b: Double)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 64,
              ] as CFDictionary) else { return nil }
        return DominantColor.of(cgImage: image)
    }

    private func lookUpApp(_ bundleID: String?) {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            appIcon = nil
            appName = nil
            return
        }
        appIcon = NSWorkspace.shared.icon(forFile: url.path)
        appName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private func refreshOutputDevice() {
        let name = AudioOutput.defaultDeviceName()
        if name != outputDevice { outputDevice = name }
    }

    // MARK: - AppleScript fallback

    private func startFallback() {
        source = .appleScript
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.pollIfWanted()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pollIfWanted() {
        guard source == .appleScript, !polling else { return }
        let wanted = viewers > 0 || isPlaying
        if !wanted {
            idleTicks += 1
            guard idleTicks >= Self.idlePollTicks else { return }
        }
        idleTicks = 0
        let running = AppleScriptPlayer.allCases.filter(\.isRunning)   // never launch a player
        guard !running.isEmpty else { update(nil); return }
        polling = true
        AppleScriptPlayer.queue.async {
            // Idle polls never prompt: only players already allowed (checked without asking).
            let readable = wanted ? running : running.filter {
                Permissions.automationStatus(bundleID: $0.rawValue, ask: false) == .granted
            }
            let infos = readable.compactMap { $0.read() }
            let best = infos.first(where: \.isPlaying) ?? infos.first
            Task { @MainActor [weak self] in
                self?.polling = false
                self?.update(best)
            }
        }
    }

    // MARK: - Controls

    private enum Command { case togglePlayPause, next, previous }

    private func command(_ c: Command) {
        switch source {
        case .adapter:
            guard let files = AdapterFiles.locate() else { return }
            let id = switch c { case .togglePlayPause: "2"; case .next: "4"; case .previous: "5" }
            AdapterStream.send(files: files, arguments: ["send", id])
        case .appleScript:
            let player = info.flatMap { AppleScriptPlayer(rawValue: $0.bundleIdentifier) }
                ?? AppleScriptPlayer.allCases.first(where: \.isRunning)
            guard let player, player.isRunning else { return }
            let verb = switch c { case .togglePlayPause: "playpause"; case .next: "next track"; case .previous: "previous track" }
            AppleScriptPlayer.queue.async {
                player.run(verb)
                Task { @MainActor [weak self] in self?.pollIfWanted() }
            }
        case .none:
            break
        }
    }
}

// MARK: - mediaremote-adapter process

/// The bundled adapter: `mediaremote-adapter.pl` and `MediaRemoteAdapter.framework`.
struct AdapterFiles: Sendable {
    static let directoryName = "mediaremote-adapter"
    let script: URL
    let framework: URL

    /// `PLATYNOTCH_MEDIAREMOTE_DIR` (development), else the app's `Resources/mediaremote-adapter/`.
    /// `PLATYNOTCH_NO_MEDIAREMOTE=1` finds none, so even a bundle uses the AppleScript
    /// fallback (`scripts/perf-idle.sh --app --music-fallback`).
    static func locate() -> AdapterFiles? {
        let env = ProcessInfo.processInfo.environment
        if env["PLATYNOTCH_NO_MEDIAREMOTE"] == "1" { return nil }
        var dirs: [URL] = []
        if let env = env["PLATYNOTCH_MEDIAREMOTE_DIR"], !env.isEmpty {
            dirs.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let res = Bundle.main.resourceURL { dirs.append(res.appendingPathComponent(directoryName, isDirectory: true)) }
        let fm = FileManager.default
        for dir in dirs {
            let files = AdapterFiles(script: dir.appendingPathComponent("mediaremote-adapter.pl"),
                                     framework: dir.appendingPathComponent("MediaRemoteAdapter.framework"))
            if fm.isReadableFile(atPath: files.script.path), fm.fileExists(atPath: files.framework.path) { return files }
        }
        return nil
    }
}

/// Runs `/usr/bin/perl mediaremote-adapter.pl <framework> stream` and parses its JSON lines
/// off the main actor.
final class AdapterStream: @unchecked Sendable {
    static let perl = URL(fileURLWithPath: "/usr/bin/perl")

    private let files: AdapterFiles
    private let onUpdate: @Sendable (NowPlayingInfo?) -> Void
    private let onExit: @Sendable (Bool, Int32) -> Void
    private let process = Process()
    private let pipe = Pipe()
    private let queue = DispatchQueue(label: "dev.platynotch.now-playing.adapter")
    // Touched only on `queue`.
    private var codec = LineCodec()
    private var parser = MediaRemoteStreamParser()
    private var receivedAny = false
    private var stopped = false

    init(files: AdapterFiles, onUpdate: @escaping @Sendable (NowPlayingInfo?) -> Void,
         onExit: @escaping @Sendable (Bool, Int32) -> Void) {
        self.files = files
        self.onUpdate = onUpdate
        self.onExit = onExit
    }

    func start() throws {
        process.executableURL = Self.perl
        // --micros: exact elapsed / duration / timestamp (the plain timestamp is whole seconds).
        process.arguments = [files.script.path, files.framework.path, "stream", "--micros", "--debounce=100"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }   // EOF: stop, or it fires forever
            guard let self else { return }
            self.queue.async { self.consume(data) }
        }
        process.terminationHandler = { [weak self] p in
            guard let self else { return }
            let status = p.terminationStatus
            self.queue.async {
                self.pipe.fileHandleForReading.readabilityHandler = nil
                guard !self.stopped else { return }
                self.onExit(self.receivedAny, status)
            }
        }
        try process.run()
    }

    func stop() {
        queue.sync { stopped = true }
        if process.isRunning { process.terminate() }   // SIGTERM ends `stream`
    }

    private func consume(_ data: Data) {
        guard !stopped, !data.isEmpty else { return }
        for line in codec.feed(data) {
            guard parser.feed(line) else { continue }
            receivedAny = true
            onUpdate(parser.current)
        }
    }

    /// `send <id>` (2 toggle play/pause, 4 next, 5 previous) or `seek <microseconds>`.
    static func send(files: AdapterFiles, arguments: [String]) {
        let p = Process()
        p.executableURL = perl
        p.arguments = [files.script.path, files.framework.path] + arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try? p.run()
    }
}

// MARK: - AppleScript fallback

/// Spotify and Music via AppleScript. Scripts run on `queue` (AppleEvents can block on the
/// consent prompt or a hung app) with a 2 s AppleScript timeout, and only for running apps.
enum AppleScriptPlayer: String, CaseIterable, Sendable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    static let queue = DispatchQueue(label: "dev.platynotch.now-playing.applescript", qos: .utility)

    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }

    /// Track length in milliseconds: Spotify reports milliseconds, Music seconds.
    private var durationMs: String {
        switch self {
        case .spotify: "(duration of t)"
        case .music: "(round ((duration of t) * 1000) rounding down)"
        }
    }

    /// Current track as `bundleID␟state␟title␟artist␟positionMs␟durationMs` (integers, so
    /// no locale decimal comma); "" when stopped. A time it cannot read is "".
    private var readScript: String {
        """
        if application id "\(rawValue)" is not running then return ""
        with timeout of 2 seconds
            tell application id "\(rawValue)"
                set playerState to (player state as text)
                if playerState is not "playing" and playerState is not "paused" then return ""
                set t to current track
                set sep to character id 31
                set pos to ""
                set len to ""
                try
                    set pos to ((round ((player position) * 1000) rounding down) as integer) as text
                end try
                try
                    set len to (\(durationMs) as integer) as text
                end try
                return "\(rawValue)" & sep & playerState & sep & (name of t as text) & sep & (artist of t as text) & sep & pos & sep & len
            end tell
        end timeout
        """
    }

    nonisolated func read() -> NowPlayingInfo? {
        guard let out = Self.execute(readScript) else { return nil }
        return NowPlayingInfo.parseAppleScript(out, now: Date())
    }

    /// `set player position` (seconds, both players).
    nonisolated func seek(to seconds: TimeInterval) {
        let whole = max(0, Int(seconds))
        _ = Self.execute("""
        if application id "\(rawValue)" is not running then return ""
        with timeout of 2 seconds
            tell application id "\(rawValue)" to set player position to \(whole)
        end timeout
        return ""
        """)
    }

    /// Music only: flips the current track's favourite (`favorited` on current Music,
    /// `loved` before it) and returns the new state; nil when neither works.
    nonisolated func toggleFavourite() -> Bool? {
        guard self == .music else { return nil }
        for property in ["favorited", "loved"] {
            let out = Self.execute("""
            if application id "\(rawValue)" is not running then return ""
            with timeout of 2 seconds
                tell application id "\(rawValue)"
                    set v to not (\(property) of current track)
                    set \(property) of current track to v
                    return v as text
                end tell
            end timeout
            """)
            if let out, out == "true" || out == "false" { return out == "true" }
        }
        return nil
    }

    /// `verb` is one of our fixed commands (playpause, next track, previous track).
    nonisolated func run(_ verb: String) {
        _ = Self.execute("""
        if application id "\(rawValue)" is not running then return ""
        with timeout of 2 seconds
            tell application id "\(rawValue)" to \(verb)
        end timeout
        return ""
        """)
    }

    private nonisolated static func execute(_ source: String) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        return error == nil ? (out.stringValue ?? "") : nil
    }
}
