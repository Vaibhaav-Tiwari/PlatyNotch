import Foundation

/// The one rule for the name a session or approval shows (Agents rows, the approval card,
/// notices, the pill): the project folder, else the first line of the title, else the
/// agent's name, else "Agent". A folder under the temporary folders (`$TMPDIR`,
/// `/var/folders/…`, `/tmp`) is not a project, and no name is a single character (an
/// orchestrator that runs agents in `$TMPDIR` used to show "T"). A worktree inside the
/// temporary folders therefore shows its title, not its folder.
public enum SessionName {
    public static func display(_ s: Session) -> String {
        if let project = project(s) { return project }
        if let title = firstLine(s.title), usable(title) { return title }
        return agent(s.agentName)
    }

    /// The project folder's name, when it is a real one.
    public static func project(_ s: Session) -> String? {
        project(project: s.project, cwd: s.cwd)
    }

    /// The same rule for any project and folder (an approval's).
    public static func project(project: String?, cwd: String?) -> String? {
        guard let p = project?.trimmingCharacters(in: .whitespacesAndNewlines), usable(p), !isTemporary(cwd) else {
            return nil
        }
        return p
    }

    /// An agent's name, never blank or a single character.
    public static func agent(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return usable(n) ? n : "Agent"
    }

    static func usable(_ name: String) -> Bool { name.count > 1 }

    static func firstLine(_ text: String?) -> String? {
        text?.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces)
    }

    /// The temporary folders: `$TMPDIR` and `NSTemporaryDirectory()` (symlinks resolved),
    /// plus the system's usual ones.
    static let temporaryRoots: [String] = {
        var roots: [String] = ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]
        let candidates: [String?] = [ProcessInfo.processInfo.environment["TMPDIR"], NSTemporaryDirectory()]
        for case let c? in candidates where !c.isEmpty {
            for path in [c, (c as NSString).resolvingSymlinksInPath] {
                let p: String = path.hasSuffix("/") ? path : path + "/"
                if p != "/", !roots.contains(p) { roots.append(p) }
            }
        }
        return roots
    }()

    /// Under a temporary folder (`extraRoots` for tests).
    static func isTemporary(_ cwd: String?, extraRoots: [String] = []) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let path: String = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return (temporaryRoots + extraRoots).contains { path.hasPrefix($0) }
    }
}
