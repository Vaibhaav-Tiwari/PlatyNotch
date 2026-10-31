import AppKit
import PlatyNotchKit
import os

/// What a side effect of "Open" does, behind closures so tests can spy on the order.
struct OpenEffects {
    /// Selects the terminal tab / session / tmux pane; reports whether it was found.
    var selectTab: @MainActor (OpenTarget, @escaping @MainActor (Bool) -> Void) -> Void
    var isRunning: @MainActor (String) -> Bool
    var activate: @MainActor (String) -> Void
    var launch: @MainActor (String) -> Void
    var folderExists: @MainActor (String) -> Bool
    var reveal: @MainActor (String) -> Void
    var notice: @MainActor (String) -> Void

    @MainActor static var live: OpenEffects {
        OpenEffects(
            selectTab: { target, done in TerminalFocus.liveSelectTab(target, done: done) },
            isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty },
            activate: { id in NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate() },
            launch: { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
            },
            folderExists: { var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue },
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: $0)]) },
            notice: { TerminalFocus.noticeSink?($0) })
    }
}

/// Opens the app that hosts a session (spec 4): a Terminal / iTerm2 tab, a tmux pane, the Claude
/// app or another host, else the folder in Finder. Never "the most recent terminal". Terminal /
/// iTerm2 tab selection needs the Automation permission; without it the app is only activated.
@MainActor
enum TerminalFocus {
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "TerminalFocus")
    private static var loggedAutomationDenied = false
    /// Shows a short notice under the notch; set by the app.
    static var noticeSink: ((String) -> Void)?

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

    // MARK: open

    /// The button title for `session` ("Open Claude", "Show folder"); nil when there is nothing to open.
    static func title(for session: Session) -> String? {
        OpenResolver.resolve(session, appName: HostAppName.lookup)?.title
    }

    static func open(_ session: Session) {
        guard let action = OpenResolver.resolve(session, appName: HostAppName.lookup) else { return }
        perform(action, effects: .live)
    }

    static func perform(_ action: OpenAction, effects: OpenEffects) {
        switch action.target {
        case .terminalTab, .iTermSession, .tmuxPane:
            // A tab that cannot be found (or Automation denied) activates the host app, once.
            let host = action.target.appBundleID
            // The scripts bring Terminal / iTerm2 forward themselves; tmux needs its host activated.
            var isTmux = false
            if case .tmuxPane = action.target { isTmux = true }
            effects.selectTab(action.target) { found in
                if let host, isTmux || !found { effects.activate(host) }
            }
        case .activate(let id):
            if effects.isRunning(id) { effects.activate(id) } else { effects.launch(id) }
        case .showFolder(let path):
            if effects.folderExists(path) { effects.reveal(path) } else { effects.notice("Folder no longer exists") }
        }
    }

    // MARK: live tab selection

    fileprivate static func liveSelectTab(_ target: OpenTarget, done: @escaping @MainActor (Bool) -> Void) {
        switch target {
        case .terminalTab(let tty):
            scripted(terminalScript, bundleID: TerminalApps.appleTerminalID, tty: tty, done: done)
        case .iTermSession(let tty):
            scripted(iTermScript, bundleID: TerminalApps.iTermID, tty: tty, done: done)
        case .tmuxPane(let tty, _):
            Task { @MainActor in done(await selectTmuxPane(tty: tty)) }
        default:
            done(false)
        }
    }

    private static func scripted(_ script: String, bundleID: String, tty: String,
                                 done: @escaping @MainActor (Bool) -> Void) {
        // Never launch a terminal that is not running.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
            done(false); return
        }
        // AppleEvents can block (first-run consent prompt, hung terminal): never on the main actor.
        scriptQueue.async {
            let result = run(script: script, argument: tty)
            Task { @MainActor in
                switch result {
                case .found: done(true)
                case .miss: done(false)
                case .failure(let code):
                    if code == -1743 {
                        if !loggedAutomationDenied {
                            loggedAutomationDenied = true
                            log.notice("Automation permission denied for \(bundleID, privacy: .public); activating the app only")
                        }
                    } else {
                        log.error("AppleScript failed (\(code)) for \(bundleID, privacy: .public)")   // incl. -1712 timeout
                    }
                    done(false)
                }
            }
        }
    }

    /// Finds the tmux pane whose pane_tty matches and selects its window and pane.
    private static func selectTmuxPane(tty: String) async -> Bool {
        guard let tmux = tmuxExecutable() else { return false }
        let runner = ProcessRunner(executableURL: tmux, stopsOnCancel: true)
        let list = await runner.run(["list-panes", "-a", "-F", "#{pane_tty} #{session_name}:#{window_index}.#{pane_index}"],
                                    timeout: .seconds(3))
        guard list.status == 0, let pane = TmuxPanes.target(forTTY: tty, listing: list.stdout) else { return false }
        let window = String(pane.split(separator: ".").dropLast().joined(separator: "."))
        let w = await runner.run(["select-window", "-t", window], timeout: .seconds(3))
        let p = await runner.run(["select-pane", "-t", pane], timeout: .seconds(3))
        return w.status == 0 && p.status == 0
    }

    private static func tmuxExecutable() -> URL? {
        for path in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
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
}
