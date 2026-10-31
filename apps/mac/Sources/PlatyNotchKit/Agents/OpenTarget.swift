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

public enum OpenResolver {
    /// First match wins (spec 4). `appName` returns an installed app's localized name, nil when
    /// the app is not installed. Never falls back to "the most recent terminal".
    public static func resolve(_ s: Session, appName: (String) -> String?) -> OpenAction? {
        let host = nonEmpty(s.hostBundleID)
        let term = nonEmpty(s.termProgram)
        let tty = nonEmpty(s.tty).flatMap(TTY.normalize)

        func action(_ target: OpenTarget, _ id: String, fallbackName: String? = nil) -> OpenAction? {
            guard let name = appName(id) ?? fallbackName else { return nil }
            return OpenAction(target: target, title: "Open \(name)")
        }

        if let tty {
            if term == "Apple_Terminal" || host == TerminalApps.appleTerminalID {
                return action(.terminalTab(tty: tty), TerminalApps.appleTerminalID, fallbackName: "Terminal")
            }
            if term == "iTerm.app" || host == TerminalApps.iTermID {
                return action(.iTermSession(tty: tty), TerminalApps.iTermID, fallbackName: "iTerm")
            }
            if term == "tmux", let host, appName(host) != nil {
                return action(.tmuxPane(tty: tty, hostBundleID: host), host)
            }
        }
        if let host, appName(host) != nil {
            return action(.activate(bundleID: host), host)
        }
        if host == nil, let id = legacyBundleID(term: term, appName: appName) {
            return action(.activate(bundleID: id), id)
        }
        if let cwd = nonEmpty(s.cwd) {
            return OpenAction(target: .showFolder(path: cwd), title: "Show folder")
        }
        return nil
    }

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
}
