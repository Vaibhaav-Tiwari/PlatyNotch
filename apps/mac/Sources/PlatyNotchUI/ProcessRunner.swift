import Foundation

/// Runs one executable with an argv array (never a shell), off the main thread: stdin is
/// /dev/null, stdout and stderr are read concurrently (so neither pipe fills and blocks
/// the child) and capped at `maxOutput` each. The child is stopped (SIGTERM, then
/// SIGKILL 2 s later) when `timeout` passes or the calling task is cancelled.
///
/// Used by `CoreRunner` (`notch` subcommands) and `ShortcutsRunner` (`/usr/bin/shortcuts`).
struct ProcessRunner: Sendable {
    struct Result: Sendable, Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut = false
        var cancelled = false

        init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false, cancelled: Bool = false) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
            self.cancelled = cancelled
        }

        var combined: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static let maxOutput = 1 << 20
    /// Between SIGTERM and SIGKILL.
    static let killGrace: Double = 2
    /// After the child exits, how long its pipes may stay open.
    static let pipeGrace: DispatchTimeInterval = .seconds(1)

    let executableURL: URL

    func run(_ args: [String], timeout: Duration = .seconds(60)) async -> Result {
        let url = executableURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return Result(status: 127, stdout: "", stderr: "\(url.lastPathComponent) not found at \(url.path)")
        }
        let control = ProcessControl()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Self.runBlocking(url: url, args: args, timeout: timeout, control: control))
                }
            }
        } onCancel: {
            control.stop(.cancelled)
        }
    }

    private static func runBlocking(url: URL, args: [String], timeout: Duration, control: ProcessControl) -> Result {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            return Result(status: 126, stdout: "", stderr: error.localizedDescription)
        }
        control.launched(p.processIdentifier)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let timer = DispatchWorkItem { control.stop(.timedOut) }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
        // Read both pipes concurrently so neither fills up and blocks the child. Once the
        // child has exited, wait at most `pipeGrace` for the rest: a grandchild that kept
        // the pipes open (and outlived a kill) must not hold the caller.
        let outBox = OutputBox(), errBox = OutputBox()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                drain(pipe.fileHandleForReading, into: box)
                group.leave()
            }
        }
        p.waitUntilExit()
        control.exited()
        timer.cancel()
        _ = group.wait(timeout: .now() + pipeGrace)
        let reason = control.reason
        return Result(status: p.terminationStatus, stdout: text(outBox.data), stderr: text(errBox.data),
                      timedOut: reason == .timedOut, cancelled: reason == .cancelled)
    }

    /// Reads to EOF but keeps only the first `maxOutput` bytes (the rest is drained so
    /// the child never blocks on a full pipe).
    private static func drain(_ handle: FileHandle, into box: OutputBox) {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            box.append(chunk, limit: maxOutput)
        }
    }

    private static func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
}

/// Output read so far, shared between a pipe reader and the caller.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var kept = Data()

    func append(_ chunk: Data, limit: Int) {
        lock.lock(); defer { lock.unlock() }
        if kept.count < limit { kept.append(chunk.prefix(limit - kept.count)) }
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return kept
    }
}

/// Stops one child process at most once, for a timeout or a cancel, whichever is first.
/// Safe from any thread.
final class ProcessControl: @unchecked Sendable {
    enum Reason: Sendable { case timedOut, cancelled }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var finished = false
    private var stopReason: Reason?

    var reason: Reason? {
        lock.lock(); defer { lock.unlock() }
        return stopReason
    }

    /// A stop asked for before launch takes effect now.
    func launched(_ pid: pid_t) {
        lock.lock()
        self.pid = pid
        let pending = stopReason != nil
        lock.unlock()
        if pending { signal(pid) }
    }

    func stop(_ reason: Reason) {
        lock.lock()
        let first = stopReason == nil && !finished
        if first { stopReason = reason }
        let target = pid
        lock.unlock()
        if first, target > 0 { signal(target) }
    }

    func exited() {
        lock.lock(); finished = true; lock.unlock()
    }

    private var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }

    private func signal(_ target: pid_t) {
        kill(target, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killGrace) { [self] in
            if !self.isFinished { kill(target, SIGKILL) }
        }
    }
}
