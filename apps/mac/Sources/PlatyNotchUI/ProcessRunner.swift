import Foundation

/// Runs one executable with an argv array (never a shell), off the main thread: stdin is
/// /dev/null, stdout and stderr are read concurrently (so neither pipe fills and blocks
/// the child) and capped at `maxOutput` each. The child is stopped (SIGTERM, then
/// SIGKILL 2 s later) when `timeout` passes, and when the calling task is cancelled only
/// if `stopsOnCancel` (otherwise it runs to completion or to its timeout).
///
/// Output is read to EOF. Only when a pipe is still held open by another process after
/// the child exited (a grandchild that inherited it), and nothing is waiting to be read,
/// is the read given up after `pipeGrace`; the result is then `truncated`.
///
/// Used by `CoreRunner` (`notch` subcommands) and `ShortcutsRunner` (`/usr/bin/shortcuts`).
struct ProcessRunner: Sendable {
    struct Result: Sendable, Equatable {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut = false
        var cancelled = false
        /// The output may be incomplete: a pipe was still held open by another process
        /// `pipeGrace` after the child exited.
        var truncated = false

        init(status: Int32, stdout: String, stderr: String, timedOut: Bool = false, cancelled: Bool = false,
             truncated: Bool = false) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
            self.cancelled = cancelled
            self.truncated = truncated
        }

        var combined: String {
            [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    static let maxOutput = 1 << 20
    /// Between SIGTERM and SIGKILL.
    static let killGrace: Double = 2
    /// After the child exits, how long a pipe may stay held open by another process with
    /// nothing to read before the read is given up (`truncated`).
    static let pipeGrace: Double = 1
    /// After the child exits, the longest the pipes are read in any case (a grandchild
    /// that keeps writing).
    static let pipeLimit: Double = 10

    let executableURL: URL
    /// Cancelling the calling task stops the child (Shortcuts' Cancel). False: the child
    /// runs to completion or to its timeout (`notch` commands, e.g. `hooks status`).
    var stopsOnCancel = true

    init(executableURL: URL, stopsOnCancel: Bool = true) {
        self.executableURL = executableURL
        self.stopsOnCancel = stopsOnCancel
    }

    func run(_ args: [String], timeout: Duration = .seconds(60)) async -> Result {
        let url = executableURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            return Result(status: 127, stdout: "", stderr: "\(url.lastPathComponent) not found at \(url.path)")
        }
        let control = ProcessControl()
        guard stopsOnCancel else {
            return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: Self.runBlocking(url: url, args: args, timeout: timeout, control: control))
                }
            }
        }
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
        // Read both pipes concurrently so neither fills up and blocks the child.
        let outBox = OutputBox(), errBox = OutputBox()
        let group = DispatchGroup()
        for (pipe, box) in [(out, outBox), (err, errBox)] {
            group.enter()
            DispatchQueue.global().async {
                drain(pipe.fileHandleForReading, into: box)
                box.finish()
                group.leave()
            }
        }
        p.waitUntilExit()
        control.exited()
        timer.cancel()
        let pipes = [(out.fileHandleForReading.fileDescriptor, outBox), (err.fileHandleForReading.fileDescriptor, errBox)]
        let complete = waitForEOF(group, pipes: pipes)
        let reason = control.reason
        return Result(status: p.terminationStatus, stdout: text(outBox.data), stderr: text(errBox.data),
                      timedOut: reason == .timedOut, cancelled: reason == .cancelled, truncated: !complete)
    }

    /// Waits for both readers to reach EOF. A pipe whose reader has not finished counts
    /// as held open by another process only while `poll` says nothing is readable (no
    /// data and no hang-up, i.e. a writer other than the exited child still has it);
    /// after `pipeGrace` of that, or `pipeLimit` in all, gives up. True when complete.
    private static func waitForEOF(_ group: DispatchGroup, pipes: [(Int32, OutputBox)]) -> Bool {
        let slice = 0.05
        var held = 0.0
        var total = 0.0
        while group.wait(timeout: .now() + slice) == .timedOut {
            total += slice
            let open = pipes.filter { !$0.1.finished }
            let progressing = open.contains { isReadable($0.0) }
            held = progressing ? 0 : held + slice
            if held >= pipeGrace || total >= pipeLimit { return false }
        }
        return true
    }

    /// Data or EOF is ready on `fd` (the reader will make progress).
    private static func isReadable(_ fd: Int32) -> Bool {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&p, 1, 0) > 0 && p.revents != 0
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
    private var done = false

    func finish() {
        lock.lock(); done = true; lock.unlock()
    }

    var finished: Bool {
        lock.lock(); defer { lock.unlock() }
        return done
    }

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
