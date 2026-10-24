import Foundation

/// The Shortcuts command line: `list` when the picker opens, `run -- <name>` on a click.
/// Arguments go to `Process` as argv elements (no shell); `--` keeps a name that starts
/// with `-` from being read as an option.
public enum ShortcutsCLI {
    public static let path = "/usr/bin/shortcuts"
    public static let listArguments = ["list"]
    public static let listTimeout: TimeInterval = 15
    /// A shortcut still running after this is stopped.
    public static let runTimeout: TimeInterval = 60
    public static let maxNames = 500

    public static func runArguments(_ name: String) -> [String] { ["run", "--", name] }

    /// One name per line, trimmed, blanks and repeats dropped, at most `maxNames`.
    public static func parseList(_ output: String) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let name = line.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            names.append(name)
            if names.count == maxNames { break }
        }
        return names
    }
}

/// How a shortcut run ended (the notice after a click).
public enum ShortcutOutcome: Equatable, Sendable {
    case done
    case failed(Int32)
    case timedOut
    case cancelled
    case unavailable(String)

    public static func from(status: Int32, timedOut: Bool, cancelled: Bool) -> ShortcutOutcome {
        if cancelled { return .cancelled }
        if timedOut { return .timedOut }
        return status == 0 ? .done : .failed(status)
    }

    public var succeeded: Bool { self == .done }

    public func message(for name: String) -> String {
        let quoted = "“\(name)”"
        switch self {
        case .done: return "\(quoted) done"
        case .failed(let code): return "\(quoted) failed (exit \(code))"
        case .timedOut: return "\(quoted) stopped after \(Int(ShortcutsCLI.runTimeout)) s"
        case .cancelled: return "\(quoted) cancelled"
        case .unavailable(let reason): return "\(quoted) could not run: \(reason)"
        }
    }
}
