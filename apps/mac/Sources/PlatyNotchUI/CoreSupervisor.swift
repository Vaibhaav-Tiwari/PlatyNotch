import Foundation
import PlatyNotchKit

/// Launches `notch serve`, appends its output to `logs/core.log`, and restarts it on unexpected exit.
@MainActor
public final class CoreSupervisor {
    public static var defaultBinaryURL: URL { CorePaths.coreBinary(name: "notch") }

    public static var defaultLogURL: URL { CorePaths.coreLog() }

    public static let killGrace: Duration = .seconds(3)

    private let binaryURL: URL
    private let arguments: [String]
    private let logURL: URL
    private let delayScale: Double
    private var backoff = RestartBackoff()
    private var process: Process?
    private var startedAt: Date?
    private var restartTask: Task<Void, Never>?
    private var stopped = true
    /// The process being replaced by `restart()`; its exit launches the new one.
    private var replacing: Process?

    /// `delayScale` scales restart delays (tests use a small value).
    public init(binaryURL: URL = CoreSupervisor.defaultBinaryURL,
                arguments: [String] = ["serve"],
                logURL: URL = CoreSupervisor.defaultLogURL,
                delayScale: Double = 1) {
        self.binaryURL = binaryURL
        self.arguments = arguments
        self.logURL = logURL
        self.delayScale = delayScale
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start() {
        guard stopped else { return }
        stopped = false
        launch()
    }

    /// Sends SIGTERM, then SIGKILL after `killGrace` if the core is still alive. Never restarts afterwards.
    public func stop() {
        stopped = true
        if let r = replacing, r.isRunning { r.terminate() }
        replacing = nil
        restartTask?.cancel()
        restartTask = nil
        guard let p = process, p.isRunning else { process = nil; return }
        process = nil
        p.terminate()
        let pid = p.processIdentifier
        Task.detached {
            try? await Task.sleep(for: CoreSupervisor.killGrace)
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    /// Stops the running core and starts a fresh one once it has exited (memory
    /// settings are only read at startup). SIGKILL after `killGrace` if it hangs.
    /// The restart does not count as a crash for the backoff.
    public func restart() {
        guard !stopped else { return }
        restartTask?.cancel()
        restartTask = nil
        guard let p = process, p.isRunning else {
            process = nil
            launch()
            return
        }
        process = nil
        replacing = p
        p.terminate()
        let pid = p.processIdentifier
        Task.detached {
            try? await Task.sleep(for: CoreSupervisor.killGrace)
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        let p = Process()
        p.executableURL = binaryURL
        p.arguments = arguments
        if let log = openLog() {
            p.standardOutput = log
            p.standardError = log
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.didExit(proc) }
        }
        do {
            try p.run()
            process = p
            startedAt = Date()
        } catch {
            process = nil
            scheduleRestart()
        }
    }

    private func didExit(_ proc: Process) {
        if replacing === proc {
            replacing = nil
            launch()
            return
        }
        guard process === proc else { return }   // stale or stopped
        process = nil
        backoff.recordExit(uptime: Date().timeIntervalSince(startedAt ?? Date()))
        scheduleRestart()
    }

    private func scheduleRestart() {
        guard !stopped else { return }
        let delay = backoff.nextDelay() * delayScale
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            self?.launch()
        }
    }

    private func openLog() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }
}
