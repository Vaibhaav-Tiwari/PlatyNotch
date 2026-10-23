import AppKit
import Observation
import PlatyNotchKit
import os

/// What is playing system-wide. Reads mediaremote-adapter's `stream` (run with /usr/bin/perl,
/// which may use MediaRemote on macOS 15.4+); if the adapter is missing or will not start,
/// falls back to AppleScript polling of Spotify and Music every 2 s.
///
/// The adapter (BSD-3-Clause) is not in the repo: `scripts/fetch-mediaremote-adapter.sh` builds
/// it into `Contents/Resources/mediaremote-adapter/` (or set `PLATYNOTCH_MEDIAREMOTE_DIR`).
@MainActor @Observable
public final class NowPlaying {
    public enum Source: Equatable { case none, adapter, appleScript }

    public private(set) var info: NowPlayingInfo?
    public private(set) var artwork: NSImage?
    public private(set) var source: Source = .none

    public var title: String? { info?.title }
    public var artist: String? { info?.artist }
    public var isPlaying: Bool { info?.isPlaying ?? false }

    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch", category: "NowPlaying")
    @ObservationIgnored private var adapter: AdapterStream?
    @ObservationIgnored private var adapterRestarts = 0
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var started = false

    public init() {}

    /// Starts reading (idempotent). Called when the Today tab is first shown.
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
    }

    /// The Today tab reports when it is on screen; the AppleScript fallback polls only then
    /// (or while music was playing at the last poll).
    public func setVisible(_ visible: Bool) {
        viewers = max(0, viewers + (visible ? 1 : -1))
    }

    public func playPause() { command(.togglePlayPause) }
    public func next() { command(.next) }
    public func previous() { command(.previous) }

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

    private func update(_ new: NowPlayingInfo?) {
        guard new != info else { return }
        if new?.artwork != info?.artwork {
            artwork = new?.artwork.flatMap { NSImage(data: $0) }
        }
        info = new
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
        guard source == .appleScript, !polling, viewers > 0 || isPlaying else { return }
        let running = AppleScriptPlayer.allCases.filter(\.isRunning)   // never launch a player
        guard !running.isEmpty else { update(nil); return }
        polling = true
        AppleScriptPlayer.queue.async {
            let infos = running.compactMap { $0.read() }
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
            AdapterStream.send(files: files, command: id)
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
    static func locate() -> AdapterFiles? {
        var dirs: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PLATYNOTCH_MEDIAREMOTE_DIR"], !env.isEmpty {
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
        process.arguments = [files.script.path, files.framework.path, "stream", "--debounce=100"]
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

    /// `send <id>`: 2 toggle play/pause, 4 next, 5 previous.
    static func send(files: AdapterFiles, command: String) {
        let p = Process()
        p.executableURL = perl
        p.arguments = [files.script.path, files.framework.path, "send", command]
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

    /// Current track as `bundleID␟state␟title␟artist`; "" when stopped.
    private var readScript: String {
        """
        if application id "\(rawValue)" is not running then return ""
        with timeout of 2 seconds
            tell application id "\(rawValue)"
                set playerState to (player state as text)
                if playerState is not "playing" and playerState is not "paused" then return ""
                set t to current track
                set sep to character id 31
                return "\(rawValue)" & sep & playerState & sep & (name of t as text) & sep & (artist of t as text)
            end tell
        end timeout
        """
    }

    nonisolated func read() -> NowPlayingInfo? {
        guard let out = Self.execute(readScript) else { return nil }
        return NowPlayingInfo.parseAppleScript(out)
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
