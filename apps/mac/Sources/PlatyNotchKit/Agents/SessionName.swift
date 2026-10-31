import Foundation

/// The name a session shows (Agents rows, notices): the project folder, else the first line
/// of its title, else the agent's name. A folder under macOS's temporary folders
/// (`/var/folders/…/T`, `/tmp`) is not a project, and no name is a single character (an
/// orchestrator that runs agents in `$TMPDIR` used to show "T").
public enum SessionName {
    public static func display(_ s: Session) -> String {
        if let project = project(s) { return project }
        if let title = s.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces), usable(title) {
            return title
        }
        return s.agentName
    }

    /// The project folder's name, when it is a real one.
    public static func project(_ s: Session) -> String? {
        guard let project = s.project?.trimmingCharacters(in: .whitespacesAndNewlines), usable(project),
              !isTemporary(s.cwd) else { return nil }
        return project
    }

    static func usable(_ name: String) -> Bool { name.count > 1 }

    /// Under the system's temporary folders.
    static func isTemporary(_ cwd: String?) -> Bool {
        guard let cwd, !cwd.isEmpty else { return false }
        let roots = ["/var/folders/", "/private/var/folders/", "/tmp/", "/private/tmp/"]
        let path: String = cwd.hasSuffix("/") ? cwd : cwd + "/"
        return roots.contains { path.hasPrefix($0) }
    }
}
