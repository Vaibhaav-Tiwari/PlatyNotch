import AppKit
import PlatyNotchKit
import os

/// Brings a session's terminal tab to the front. Needs the Automation permission for Terminal /
/// iTerm2 (Info.plist NSAppleEventsUsageDescription is added in Task 11); without it we only
/// activate the app.
@MainActor
enum TerminalFocus {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "TerminalFocus")
    private static var loggedAutomationDenied = false

    // The tty is never spliced into script source: it is passed as `argv` to `on run`.
    private static let terminalScript = """
    on run argv
        set wanted to item 1 of argv
        with timeout of 3 seconds
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is wanted then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        end timeout
        return "miss"
    end run
    """

    private static let iTermScript = """
    on run argv
        set wanted to item 1 of argv
        with timeout of 3 seconds
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (tty of s) is wanted then
                            select w
                            select t
                            select s
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        end timeout
        return "miss"
    end run
    """

    static func focus(session: Session) {
        let target = TerminalApps.target(termProgram: session.termProgram, isRunning: isRunning)
        switch target {
        case .appleTerminal:
            scriptedFocus(script: terminalScript, bundleID: TerminalApps.appleTerminalID, session: session)
        case .iTerm:
            scriptedFocus(script: iTermScript, bundleID: TerminalApps.iTermID, session: session)
        case .activate(let id):
            if !activate(bundleID: id) { activateByAncestry(session) }
        case .pidAncestry:
            activateByAncestry(session)
        }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    @discardableResult
    private static func activate(bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return false }
        return app.activate()
    }

    private static func scriptedFocus(script: String, bundleID: String, session: Session) {
        // Never launch a terminal that is not running, and never run with an unvalidated tty.
        guard isRunning(bundleID) else { activateByAncestry(session); return }
        guard let tty = session.tty.flatMap(TTY.normalize) else { activate(bundleID: bundleID); return }
        // AppleEvents can block (first-run consent prompt, hung terminal): never on the main actor.
        scriptQueue.async {
            let result = run(script: script, argument: tty)
            Task { @MainActor in
                switch result {
                case .found: break
                case .miss:   // no tab with that tty: at least bring the app forward
                    activate(bundleID: bundleID)
                case .failure(let code):
                    if code == -1743 {
                        if !loggedAutomationDenied {
                            loggedAutomationDenied = true
                            log.notice("Automation permission denied for \(bundleID, privacy: .public); activating the app only")
                        }
                    } else {
                        log.error("AppleScript failed (\(code)) for \(bundleID, privacy: .public)")   // incl. -1712 timeout
                    }
                    activate(bundleID: bundleID)   // single fallback, no retry
                }
            }
        }
    }

    private static let scriptQueue = DispatchQueue(label: "dev.platynotch.terminal-focus", qos: .userInitiated)

    private enum RunResult: Sendable { case found, miss, failure(Int) }

    /// Calls the script's `run` handler with one string argument (`argv`). Fresh NSAppleScript per call.
    private nonisolated static func run(script source: String, argument: String) -> RunResult {
        guard let script = NSAppleScript(source: source) else { return .failure(-1) }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let args = NSAppleEventDescriptor.list()
        args.insert(NSAppleEventDescriptor(string: argument), at: 1)
        event.setParam(args, forKeyword: AEKeyword(keyDirectObject))
        var error: NSDictionary?
        let out = script.executeAppleEvent(event, error: &error)
        if let error { return .failure((error[NSAppleScript.errorNumber] as? Int) ?? -1) }
        return out.stringValue == "ok" ? .found : .miss
    }

    // MARK: tracking

    nonisolated(unsafe) private static var lastActive: [String: Date] = [:]
    nonisolated(unsafe) private static var tracker: NSObjectProtocol?

    /// Records when known terminals were last frontmost, for the tmux fallback. Call once at launch.
    static func startTracking() {
        guard tracker == nil else { return }
        tracker = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier, TerminalApps.knownTerminalIDs.contains(id) else { return }
            MainActor.assumeIsolated { lastActive[id] = Date() }
        }
    }

    // MARK: pid ancestry

    private static func activateByAncestry(_ session: Session) {
        guard let pid = session.pid.flatMap({ pid_t(exactly: $0) }), pid > 1 else {
            activateMostRecentTerminal(); return
        }
        var current = pid
        for _ in 0..<64 {   // bounded walk
            if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil,
               app.activationPolicy == .regular {
                app.activate()
                return
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
            current = parent
        }
        activateMostRecentTerminal()
    }

    /// Ancestry dead-ends at launchd (typical under tmux, whose server is detached from the terminal):
    /// activate the most recently active running terminal we have seen (tracked via `startTracking`),
    /// else the most recently launched one.
    private static func activateMostRecentTerminal() {
        let running = TerminalApps.knownTerminalIDs.compactMap {
            id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first.map { (id, $0) }
        }
        let best = running.max { a, b in
            let da = lastActive[a.0] ?? .distantPast, db = lastActive[b.0] ?? .distantPast
            if da != db { return da < db }
            return (a.1.launchDate ?? .distantPast) < (b.1.launchDate ?? .distantPast)
        }
        best?.1.activate()
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
