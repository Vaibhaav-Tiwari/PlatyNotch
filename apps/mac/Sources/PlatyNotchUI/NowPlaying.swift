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
    /// Music's favourite state: read when the track changes (only when Music already allows
    /// PlatyNotch, so never a prompt) and after a toggle; nil while not known.
    public private(set) var liked: Bool?
    /// Why the last heart click did not work (cleared by the next track or after a while).
    public private(set) var likeMessage: String?
    /// Buttons for `likeMessage` when Music refused PlatyNotch (Automation).
    private(set) var likeHelp: PermissionHelp?
    /// A heart click is waiting for Music's answer.
    public private(set) var likeBusy = false

    public var title: String? { info?.title }
    public var artist: String? { info?.artist }
    public var isPlaying: Bool { info?.isPlaying ?? false }
    /// When playback last stopped with a track still loaded (music stays live for 10
    /// minutes after a pause, spec 6.2); nil while playing, with nothing loaded, and once
    /// `pauseWindow` has passed (cleared by a sleeping task, and at once after a wake or a
    /// clock change), so the pill and Now drop paused music when it runs out.
    public private(set) var pausedAt: Date?
    /// How long paused music stays live.
    public static let pauseLength: TimeInterval = 600
    /// `pauseLength`; tests shorten it.
    @ObservationIgnored var pauseWindow: TimeInterval = NowPlaying.pauseLength
    @ObservationIgnored private var pauseExpiry: Task<Void, Never>?
    @ObservationIgnored private var clockObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The clock the pause expiry re-checks against (tests move it).
    @ObservationIgnored var pauseClock: () -> Date = Date.init
    /// Where playback is (nil when the player gives no times).
    public var clock: PlaybackClock? { info.flatMap { PlaybackClock(info: $0, now: Date()) } }
    /// Favourites work for Apple Music only (Spotify has no AppleScript for it).
    public var canLike: Bool { info?.bundleIdentifier == AppleScriptPlayer.music.rawValue }
    /// Called when `isPlaying` changes (the visualiser follows it).
    @ObservationIgnored public var onPlayingChange: ((Bool) -> Void)?

    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "NowPlaying")
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
    /// Perf runs only (`LaunchOptions.fakeNowPlaying`): `start` reports a fake track as
    /// playing and reads no player.
    @ObservationIgnored public var fakePlaying = false
    /// Smoke runs: never send an Apple Event to a player (no AppleScript fallback, no heart).
    @ObservationIgnored var sendsAppleEvents = true
    /// The Apple Events behind the heart (tests pass their own).
    @ObservationIgnored var music: MusicScripting = .system
    /// Which build Music last answered, so a refusal after a rebuild is explained.
    @ObservationIgnored var grants = AutomationGrants(defaults: .standard, identity: { CodeIdentity.current })
    @ObservationIgnored private var likeMessageTask: Task<Void, Never>?
    static let likeMessageSeconds: Double = 30

    public init() {}

    /// Starts reading (idempotent). Called by the music widget when it starts (at launch
    /// when the widget is enabled).
    public func start() {
        guard !started else { return }
        started = true
        observeClock()
        if fakePlaying {
            apply(NowPlayingInfo(bundleIdentifier: "dev.platynotch.fake", title: "Perf run", artist: "PlatyNotch",
                                 isPlaying: true))
            return
        }
        if let files = AdapterFiles.locate() {
            startAdapter(files)
        } else if !sendsAppleEvents {
            Self.log.notice("smoke run: no mediaremote-adapter and no AppleScript fallback")
        } else {
            Self.log.notice("mediaremote-adapter not bundled; using AppleScript for Spotify / Music")
            startFallback()
        }
    }

    /// Renders: never read the Mac's real player (`start` then does nothing); a render sets
    /// its track with `debugApply`.
    func makeInertForRendering() { started = true }

    public func stop() {
        started = false
        for (center, token) in clockObservers { center.removeObserver(token) }
        clockObservers = []
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
        if visible {
            refreshOutputDevice()
            readLiked()   // the heart shows Music's state when the tile appears
        }
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
    /// first time, on this click). The heart follows Music's answer; a refusal or failure
    /// says why under the controls instead of doing nothing.
    public func toggleLike() {
        guard sendsAppleEvents, canLike, !likeBusy else { return }
        guard music.isRunning() else {
            showLikeMessage("Music is not running.")
            return
        }
        likeBusy = true
        let title = info?.title
        let toggle = music.toggle
        AppleScriptPlayer.queue.async {
            let outcome = toggle()
            Task { @MainActor [weak self] in self?.likeFinished(outcome, title: title) }
        }
    }

    private func likeFinished(_ outcome: MusicFavourite.Outcome, title: String?) {
        likeBusy = false
        guard info?.title == title else { return }
        if case .state(let on) = outcome {
            liked = on
            grants.noteAccepted(AppleScriptPlayer.music.rawValue)
            showLikeMessage(nil)
            return
        }
        let history = grants.history(AppleScriptPlayer.music.rawValue)
        let help: PermissionHelp? = outcome == .notAllowed ? .automation(reset: history != .thisBuild) : nil
        showLikeMessage(MusicFavourite.message(outcome, history: history), help: help)
    }

    private func showLikeMessage(_ text: String?, help: PermissionHelp? = nil) {
        likeMessage = text
        likeHelp = text == nil ? nil : help
        likeMessageTask?.cancel()
        guard text != nil else { return }
        likeMessageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.likeMessageSeconds))
            guard !Task.isCancelled else { return }
            self?.likeMessage = nil
            self?.likeHelp = nil
        }
    }

    /// The track's favourite state, when the tile appears or the track changes while it is
    /// shown, and only when Music already allows PlatyNotch (checked without asking), so
    /// reading it never shows a prompt.
    private func readLiked() {
        guard sendsAppleEvents, canLike, music.isRunning() else { return }
        let title = info?.title
        let music = self.music
        AppleScriptPlayer.queue.async {
            guard music.allowedWithoutAsking() else { return }
            let outcome = music.read()
            Task { @MainActor [weak self] in
                guard let self, self.info?.title == title, !self.likeBusy, case .state(let on) = outcome else { return }
                self.liked = on
            }
        }
    }

    /// Tests: feed a report as if the reader had sent it.
    func debugApply(_ new: NowPlayingInfo?, now: Date = Date()) { apply(new, now: now) }

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
        let trackChanged = new?.title != info?.title || new?.bundleIdentifier != info?.bundleIdentifier
        if trackChanged {
            liked = nil
            showLikeMessage(nil)
        }
        info = new
        if new == nil || isPlaying {
            setPaused(nil)
        } else if wasPlaying {
            // Paused (or stopped) now; a track first seen paused was not paused "just now".
            setPaused(now)
        } else if trackChanged {
            // A new track loaded without playing was not paused by the user.
            setPaused(nil)
        }
        // Only while a music view is on screen: nothing is read for a heart nobody sees.
        if trackChanged, viewers > 0 { readLiked() }
        if isPlaying != wasPlaying { onPlayingChange?(isPlaying) }
        if viewers > 0 { refreshOutputDevice() }
    }

    /// Sets the pause and (re)schedules its expiry; nil cancels it.
    private func setPaused(_ date: Date?) {
        pauseExpiry?.cancel()
        pauseExpiry = nil
        if pausedAt != date { pausedAt = date }
        guard let date else { return }
        let wait: TimeInterval = date.addingTimeInterval(pauseWindow).timeIntervalSince(pauseClock())
        guard wait > 0 else { pausedAt = nil; return }
        pauseExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.recheckPause()
        }
    }

    /// After a wake or a clock change: a pause past its window ends at once; one still
    /// inside it is rescheduled for what is left.
    func recheckPause() {
        guard let pausedAt else { return }
        let age: TimeInterval = pauseClock().timeIntervalSince(pausedAt)
        if age >= pauseWindow || age < 0 {
            setPaused(nil)
        } else {
            setPaused(pausedAt)
        }
    }

    /// Re-checks the pause on wake and on a system clock change (while reading).
    private func observeClock() {
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPause() }
        }
        let center = NotificationCenter.default
        let clockChange = center.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheckPause() }
        }
        clockObservers = [(workspace, wake), (center, clockChange)]
    }

    /// A report with an elapsed time but no timestamp is stamped once, when it arrives (so
    /// `clock` does not restart from `elapsed` on every read). An unchanged elapsed time
    /// keeps the earlier stamp only for the same track in the same state (elapsed, playing,
    /// title and player all equal): a diff about something else does not move the clock, but
    /// a pause, resume or new track at the same elapsed time is stamped afresh (C6).
    static func stamped(_ new: NowPlayingInfo?, previous: NowPlayingInfo?, now: Date) -> NowPlayingInfo? {
        guard var new, new.elapsed != nil, new.timestamp == nil else { return new }
        if let previous, sameClock(previous, new), let at = previous.timestamp {
            new.timestamp = at
        } else {
            new.timestamp = now
        }
        return new
    }

    private static func sameClock(_ a: NowPlayingInfo, _ b: NowPlayingInfo) -> Bool {
        a.elapsed == b.elapsed && a.isPlaying == b.isPlaying && a.title == b.title
            && a.bundleIdentifier == b.bundleIdentifier
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
        guard sendsAppleEvents else { return }
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
    /// `loved` before it) and returns the new state, or why it could not.
    nonisolated func toggleFavourite() -> MusicFavourite.Outcome {
        favourite { property in
            """
            set v to not (\(property) of current track)
            set \(property) of current track to v
            return v as text
            """
        }
    }

    /// Music only: the current track's favourite state.
    nonisolated func readFavourite() -> MusicFavourite.Outcome {
        favourite { property in "return (\(property) of current track) as text" }
    }

    /// Runs `body` (given the property name) inside Music, trying `loved` only when this
    /// Music does not know `favorited`.
    private nonisolated func favourite(_ body: (String) -> String) -> MusicFavourite.Outcome {
        guard self == .music else { return .failed(0) }
        var last = MusicFavourite.Outcome.unknownTerm
        for property in MusicFavourite.properties {
            let (out, code) = Self.executeDetailed("""
            if application id "\(rawValue)" is not running then return ""
            with timeout of 2 seconds
                tell application id "\(rawValue)"
                    if player state is stopped then return ""
                    \(body(property))
                end tell
            end timeout
            """)
            last = MusicFavourite.outcome(output: out, errorNumber: code)
            if !MusicFavourite.tryNextProperty(after: last) { return last }
        }
        return last
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
        executeDetailed(source).output
    }

    /// The script's text, or its AppleScript error number.
    private nonisolated static func executeDetailed(_ source: String) -> (output: String?, error: Int?) {
        guard let script = NSAppleScript(source: source) else { return (nil, -1) }
        var error: NSDictionary?
        let out = script.executeAndReturnError(&error)
        if let error { return (nil, (error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return (out.stringValue ?? "", nil)
    }
}

/// The Apple Events behind Music's heart: one seam so tests never script Music.
struct MusicScripting: Sendable {
    var isRunning: @MainActor () -> Bool
    /// Automation for Music already granted (checked without asking; off the main thread).
    var allowedWithoutAsking: @Sendable () -> Bool
    var toggle: @Sendable () -> MusicFavourite.Outcome
    var read: @Sendable () -> MusicFavourite.Outcome

    static let system = MusicScripting(
        isRunning: { AppleScriptPlayer.music.isRunning },
        allowedWithoutAsking: {
            Permissions.automationStatus(bundleID: AppleScriptPlayer.music.rawValue, ask: false) == .granted
        },
        toggle: { AppleScriptPlayer.music.toggleFavourite() },
        read: { AppleScriptPlayer.music.readFavourite() })
}
