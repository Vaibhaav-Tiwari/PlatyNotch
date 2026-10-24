import Foundation
import PlatyNotchKit

/// Lists and runs the user's Shortcuts. Tests and smoke runs use a fake; the app uses
/// `ShortcutsRunner`.
protocol ShortcutsRunning: Sendable {
    /// The shortcut names; nil when they could not be listed (missing CLI, error, timeout).
    func list() async -> [String]?
    /// Runs one shortcut. Cancelling the calling task stops it (`.cancelled`).
    func run(_ name: String) async -> ShortcutOutcome
}

/// `/usr/bin/shortcuts` through `ProcessRunner`: `list` (only when the picker opens) and
/// `run -- <name>` (only on a click), the name as one argv element, no shell. A run still
/// going after `ShortcutsCLI.runTimeout` is stopped.
struct ShortcutsRunner: ShortcutsRunning {
    let executableURL: URL
    let listTimeout: Duration
    let runTimeout: Duration

    init(executableURL: URL = URL(fileURLWithPath: ShortcutsCLI.path),
         listTimeout: Duration = .seconds(ShortcutsCLI.listTimeout),
         runTimeout: Duration = .seconds(ShortcutsCLI.runTimeout)) {
        self.executableURL = executableURL
        self.listTimeout = listTimeout
        self.runTimeout = runTimeout
    }

    private var runner: ProcessRunner { ProcessRunner(executableURL: executableURL) }

    func list() async -> [String]? {
        let r = await runner.run(ShortcutsCLI.listArguments, timeout: listTimeout)
        guard r.status == 0, !r.timedOut, !r.cancelled else { return nil }
        return ShortcutsCLI.parseList(r.stdout)
    }

    func run(_ name: String) async -> ShortcutOutcome {
        guard LaunchPins.isValidName(name) else { return .unavailable("not a shortcut name") }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return .unavailable("Shortcuts is not available on this Mac")
        }
        let r = await runner.run(ShortcutsCLI.runArguments(name), timeout: runTimeout)
        return ShortcutOutcome.from(status: r.status, timedOut: r.timedOut, cancelled: r.cancelled)
    }
}

/// Never starts a process (smoke runs).
struct NoShortcuts: ShortcutsRunning {
    func list() async -> [String]? { nil }
    func run(_ name: String) async -> ShortcutOutcome { .unavailable("not in this run") }
}
