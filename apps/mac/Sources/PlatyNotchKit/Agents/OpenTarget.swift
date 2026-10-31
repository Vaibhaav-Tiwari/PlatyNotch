import Foundation

/// Where "Open" takes the user for a session (spec 4).
public enum OpenTarget: Equatable, Sendable {
    case terminalTab(tty: String)
    case iTermSession(tty: String)
    case tmuxPane(tty: String, hostBundleID: String)
    case activate(bundleID: String)
    case showFolder(path: String)

    /// The app this opens or brings forward; nil for Finder's "Show folder".
    public var appBundleID: String? {
        switch self {
        case .terminalTab: TerminalApps.appleTerminalID
        case .iTermSession: TerminalApps.iTermID
        case .tmuxPane(_, let host): host
        case .activate(let id): id
        case .showFolder: nil
        }
    }
}

/// The resolved target and the button's title.
public struct OpenAction: Equatable, Sendable {
    public let target: OpenTarget
    public let title: String

    public init(target: OpenTarget, title: String) {
        self.target = target
        self.title = title
    }
}

/// A reverse-DNS bundle identifier: letters, digits, dots and hyphens, at least one dot, no
/// empty label, at most 255 bytes. The core checks the same; the app checks again before use.
public enum BundleID {
    /// `s` when valid, else nil (an invalid value counts as absent).
    public static func valid(_ s: String?) -> String? {
        guard let s, !s.isEmpty, s.utf8.count <= 255, s.contains(".") else { return nil }
        for label in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty else { return nil }
            for b in label.utf8 {
                let ok: Bool = (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
                if !ok { return nil }
            }
        }
        return s
    }
}

public enum OpenResolver {
    /// First match wins (spec 4, with two changes from review: tmux is checked before the
    /// host-based Terminal / iTerm2 rules, and a host of Terminal or iTerm2 is ignored when
    /// `term_program` names another known app, because an app started from a shell inherits its
    /// shell's `__CFBundleIdentifier`). `appName` returns an installed app's localized name, nil
    /// when the app is not installed. Never falls back to "the most recent terminal".
    public static func resolve(_ s: Session, appName: (String) -> String?) -> OpenAction? {
        let host = BundleID.valid(s.hostBundleID)
        let term = nonEmpty(s.termProgram)
        let tty = nonEmpty(s.tty).flatMap(TTY.normalize)
        let hostIsTerminalApp: Bool = host == TerminalApps.appleTerminalID || host == TerminalApps.iTermID

        func action(_ target: OpenTarget, _ id: String) -> OpenAction? {
            guard let name = appName(id) else { return nil }
            return OpenAction(target: target, title: "Open \(name)")
        }

        if let tty {
            if term == "tmux", let host, appName(host) != nil {
                if let a = action(.tmuxPane(tty: tty, hostBundleID: host), host) { return a }
            }
            // The host counts only when TERM_PROGRAM does not name some other known app.
            let hostFits: Bool = term == nil || !knownTermPrograms.contains(term ?? "")
            if term == "Apple_Terminal" || (hostFits && host == TerminalApps.appleTerminalID) {
                if let a = action(.terminalTab(tty: tty), TerminalApps.appleTerminalID) { return a }
            }
            if term == "iTerm.app" || (hostFits && host == TerminalApps.iTermID) {
                if let a = action(.iTermSession(tty: tty), TerminalApps.iTermID) { return a }
            }
        }
        // A real host app (the Claude app, Cursor...). Terminal and iTerm2 as host may only be
        // inherited from a shell, so a known TERM_PROGRAM below gets to speak first.
        if let host, !hostIsTerminalApp, appName(host) != nil {
            return action(.activate(bundleID: host), host)
        }
        if let id = legacyBundleID(term: term, appName: appName) {
            return action(.activate(bundleID: id), id)
        }
        if let host, appName(host) != nil {
            return action(.activate(bundleID: host), host)
        }
        if let cwd = nonEmpty(s.cwd) {
            return OpenAction(target: .showFolder(path: cwd), title: "Show folder")
        }
        return nil
    }

    private static let knownTermPrograms: Set<String> = ["Apple_Terminal", "iTerm.app", "tmux", "ghostty", "WarpTerminal", "vscode"]

    /// An older hook records only TERM_PROGRAM.
    private static func legacyBundleID(term: String?, appName: (String) -> String?) -> String? {
        let id: String
        switch term {
        case "Apple_Terminal": id = TerminalApps.appleTerminalID
        case "iTerm.app": id = TerminalApps.iTermID
        case "ghostty": id = "com.mitchellh.ghostty"
        case "WarpTerminal": id = "dev.warp.Warp-Stable"
        case "vscode":
            guard let found = TerminalApps.vscodeFamily.first(where: { appName($0) != nil }) else { return nil }
            id = found
        default: return nil
        }
        return appName(id) == nil ? nil : id
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

public enum TmuxPanes {
    /// `listing` is `tmux list-panes -a -F '#{pane_tty} #{session_name}:#{window_index}.#{pane_index}'`.
    public static func target(forTTY tty: String, listing: String) -> String? {
        guard let want = TTY.normalize(tty) else { return nil }
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, TTY.normalize(String(parts[0])) == want else { continue }
            return String(parts[1])
        }
        return nil
    }

    /// The window part of a pane target: `main:1.2` → `main:1`.
    public static func windowTarget(forPane pane: String) -> String {
        guard let dot = pane.lastIndex(of: ".") else { return pane }
        return String(pane[..<dot])
    }
}
