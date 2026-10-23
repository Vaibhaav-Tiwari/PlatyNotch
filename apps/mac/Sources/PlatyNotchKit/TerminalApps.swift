import Foundation

/// How to bring a session's terminal forward, decided from `term_program`.
public enum TerminalApps {
    public enum Target: Equatable, Sendable {
        case appleTerminal
        case iTerm
        case activate(String)   // bundle id
        case pidAncestry
    }

    public static let appleTerminalID = "com.apple.Terminal"
    public static let iTermID = "com.googlecode.iterm2"
    /// VS Code and forks that all report TERM_PROGRAM=vscode (Cursor, VSCodium).
    public static let vscodeFamily = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "com.vscodium"]

    /// Every terminal app we know, for the "most recently active terminal" fallback.
    public static let knownTerminalIDs = [appleTerminalID, iTermID, "com.mitchellh.ghostty",
                                          "dev.warp.Warp-Stable"] + vscodeFamily

    public static func target(termProgram: String?, isRunning: (String) -> Bool) -> Target {
        switch termProgram {
        case "Apple_Terminal": return .appleTerminal
        case "iTerm.app": return .iTerm
        case "ghostty": return .activate("com.mitchellh.ghostty")
        case "WarpTerminal": return .activate("dev.warp.Warp-Stable")
        case "vscode":
            return .activate(vscodeFamily.first(where: isRunning) ?? "com.microsoft.VSCode")
        default: return .pidAncestry   // tmux, unknown, absent
        }
    }
}
