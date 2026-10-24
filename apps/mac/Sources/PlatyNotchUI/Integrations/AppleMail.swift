import AppKit
import Foundation
import PlatyNotchKit

/// Everything the Mail widget does to the system (a seam: tests and smoke runs use fakes
/// that never look at Mail, run a process or send an Apple Event).
@MainActor
struct MailSystem {
    nonisolated static let mailID = "com.apple.mail"

    /// The running Mail's pid (`NSWorkspace`), nil when Mail is not running. Nothing else
    /// is ever done to Mail while this is nil, and the script addresses this pid only.
    var mailPID: @MainActor () -> pid_t?
    /// Automation status for Mail; `ask: true` may show the macOS prompt (only from the
    /// widget's Allow button). Off the main thread.
    var automation: @Sendable (_ ask: Bool) async -> Permissions.State
    /// Runs `/usr/bin/osascript` with these arguments (killable `ProcessRunner`; stopping
    /// the calling task kills it).
    var osascript: @Sendable (_ args: [String]) async -> ProcessRunner.Result
    /// Opens a `message:` link (Mail is already running when this is called).
    var open: @MainActor (URL) -> Void
    /// Brings the running Mail to the front.
    var activateMail: @MainActor () -> Void
    /// Calls `onChange` when Mail launches or quits; returns what `unwatch` removes.
    var watchMail: @MainActor (_ onChange: @escaping @MainActor () -> Void) -> [NSObjectProtocol]
    var unwatch: @MainActor ([NSObjectProtocol]) -> Void
    /// Waits between reads (tests release it by hand).
    var sleep: @Sendable (TimeInterval) async -> Void

    static let system = MailSystem(
        mailPID: {
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == mailID && !$0.isTerminated }?.processIdentifier
        },
        automation: { ask in
            await Task.detached { Permissions.automationStatus(bundleID: mailID, ask: ask) }.value
        },
        osascript: { args in
            await ProcessRunner(executableURL: URL(fileURLWithPath: MailScript.executable), stopsOnCancel: true)
                .run(args, timeout: .seconds(MailScript.timeout))
        },
        open: { NSWorkspace.shared.open($0) },
        activateMail: {
            NSRunningApplication.runningApplications(withBundleIdentifier: mailID).first?.activate()
        },
        watchMail: { onChange in
            let ws = NSWorkspace.shared.notificationCenter
            let names = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification]
            return names.map { name in
                ws.addObserver(forName: name, object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard app?.bundleIdentifier == mailID else { return }
                    MainActor.assumeIsolated { onChange() }
                }
            }
        },
        unwatch: { tokens in
            for t in tokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        },
        sleep: { try? await Task.sleep(for: .seconds($0)) })

    /// Mail is never running, nothing is run (smoke runs).
    static let inert = MailSystem(
        mailPID: { nil }, automation: { _ in .unavailable("Inert.") },
        osascript: { _ in ProcessRunner.Result(status: 1, stdout: "", stderr: "inert") },
        open: { _ in }, activateMail: {}, watchMail: { _ in [] }, unwatch: { _ in },
        sleep: { _ in })
}
