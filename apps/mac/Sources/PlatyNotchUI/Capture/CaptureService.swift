import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Observation
import os
import PlatyNotchKit

/// Captures the frontmost window's text every `interval` and sends it to the core as
/// `capture.text`, only while memory is enabled, Accessibility is granted and capture is
/// not paused. Skips excluded apps, PlatyNotch itself, System Settings' password panes,
/// secure text fields and anything while secure input is on.
@MainActor @Observable
public final class CaptureService {
    public static let pausedUntilKey = "capture.pausedUntil"

    public private(set) var status: CaptureStatus = .off {
        didSet { if status != oldValue { Self.log.info("capture \(String(describing: self.status), privacy: .public)") } }
    }
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "capture")
    /// Drives the menu bar capture dot.
    public var isCapturing: Bool { status.isCapturing }
    public private(set) var settings = CaptureSettings()

    @ObservationIgnored private let send: @Sendable (Envelope) async throws -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let walkQueue = DispatchQueue(label: "platynotch.capture.ax", qos: .utility)
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pauseTask: Task<Void, Never>?
    @ObservationIgnored private var walking = false
    @ObservationIgnored private var lastHashes: [String: Int] = [:]
    @ObservationIgnored private var interval: Duration = .seconds(CaptureSettings.defaultIntervalSeconds)
    @ObservationIgnored private var watcher: ConfigFileWatcher?

    init(send: @escaping @Sendable (Envelope) async throws -> Void, defaults: UserDefaults = .standard) {
        self.send = send
        self.defaults = defaults
    }

    public convenience init(client: CoreClient) {
        self.init(send: { try await client.send($0) })
    }

    /// Reads `config.json` now and again whenever it changes, starting or stopping capture.
    public func watchConfig(url: URL = CorePaths.config()) {
        watcher = ConfigFileWatcher(url: url) { [weak self] in
            self?.apply(CaptureSettings.read(from: url))
        }
        apply(CaptureSettings.read(from: url))
    }

    /// New settings (the config file, or the Settings window once it exists).
    public func apply(_ new: CaptureSettings) {
        if new == settings, (loop != nil) == new.enabled { return }   // unrelated change in the directory
        settings = new
        if new.enabled {
            start(interval: .seconds(new.intervalSeconds))
        } else {
            stop()
        }
    }

    /// Captures now and then every `interval` (no-ops while off, paused or untrusted).
    func start(interval: Duration) {
        if loop != nil, interval == self.interval { refreshStatus(); return }
        loop?.cancel()
        self.interval = interval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
        refreshStatus()
    }

    func stop() {
        loop?.cancel()
        loop = nil
        lastHashes = [:]
        status = .off
    }

    // MARK: - Pause

    public var pausedUntil: Date? {
        let t = defaults.double(forKey: Self.pausedUntilKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    public func pause(for duration: TimeInterval = 3600) {
        let until = Date().addingTimeInterval(duration)
        defaults.set(until.timeIntervalSince1970, forKey: Self.pausedUntilKey)
        refreshStatus()
    }

    public func resume() {
        defaults.removeObject(forKey: Self.pausedUntilKey)
        refreshStatus()
    }

    private func refreshStatus() {
        let now = Date()
        // Accessibility trust is read without prompting; onboarding asks for it.
        status = loop == nil ? .off : CaptureStatus.resolve(enabled: settings.enabled, trusted: AXIsProcessTrusted(),
                                                            pausedUntil: pausedUntil, now: now)
        pauseTask?.cancel()
        if case .paused(let until) = status {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSince(now)) + 0.5))
                guard !Task.isCancelled else { return }
                self?.refreshStatus()
            }
        }
    }

    // MARK: - Capture

    private func tick() {
        refreshStatus()
        guard status == .capturing, !walking, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return }
        let filter = CaptureFilter(excluded: Set(settings.excludeApps)
            .union([Bundle.main.bundleIdentifier].compactMap { $0 }))
        let bundleID = app.bundleIdentifier
        guard !filter.isExcluded(bundleID), let bundleID else { return }
        let appName = app.localizedName ?? bundleID
        let pid = app.processIdentifier
        walking = true
        walkQueue.async { [weak self] in
            let result = AXTextReader.focusedWindowText(pid: pid)
            Task { @MainActor [weak self] in
                self?.finish(result, bundleID: bundleID, appName: appName, pid: pid, filter: filter)
            }
        }
    }

    private func finish(_ result: AXTextReader.Result?, bundleID: String, appName: String, pid: pid_t,
                        filter: CaptureFilter) {
        walking = false
        guard status == .capturing, let result,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              !CaptureFilter.isSensitiveWindow(bundleID: bundleID, title: result.title) else { return }
        let key = bundleID + "\u{1F}" + (result.title ?? "")
        guard filter.shouldCapture(bundleID: bundleID, secureInput: IsSecureEventInputEnabled(),
                                   text: result.text, lastHash: lastHashes[key]) else { return }
        if lastHashes.count > 256 { lastHashes = [:] }
        lastHashes[key] = CaptureFilter.hash(result.text)
        guard let env = try? CaptureFilter.envelope(appBundle: bundleID, appName: appName, windowTitle: result.title,
                                                    url: result.url, text: result.text, at: Date()) else { return }
        let send = self.send
        Self.log.debug("capture.text \(bundleID, privacy: .public) \(result.text.count) chars")
        Task { [weak self] in
            do { try await send(env) } catch { self?.lastHashes[key] = nil }   // resend when reconnected
        }
    }
}

/// Calls `onChange` (on the main actor) when a file is written, replaced or created.
/// Watches the directory too, since an atomic save renames a new file over the old one.
@MainActor
final class ConfigFileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var dirSource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        dirSource = Self.watch(dir.path, events: .write) { [weak self] in self?.changed() }
        watchFile()
    }

    deinit {
        dirSource?.cancel()
        fileSource?.cancel()
    }

    private func changed() {
        watchFile()
        onChange()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = Self.watch(url.path, events: [.write, .extend, .delete, .rename]) { [weak self] in
            self?.changed()
        }
    }

    private static func watch(_ path: String, events: DispatchSource.FileSystemEvent,
                              handler: @escaping @MainActor () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
