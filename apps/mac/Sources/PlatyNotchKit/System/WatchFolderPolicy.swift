import Foundation

/// Which folders the downloads watcher may take as its optional second folder. The
/// folder is stat'ed at every launch with no button in between, so it must never be in
/// a place macOS guards with a privacy prompt (Desktop, Documents, iCloud Drive, other
/// apps' data, removable and network volumes) or another user's home. Folders inside
/// ~/Downloads are fine: the Downloads grant (and its stamp) covers them. Pure.
public enum WatchFolderPolicy {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// Why, for the settings.
        case rejected(String)
    }

    /// `path` should be absolute (the chosen folder, then its canonical form);
    /// `home` is the user's home folder.
    public static func check(_ path: String, home: String) -> Verdict {
        guard path.hasPrefix("/") else { return .rejected("Choose a folder on this Mac.") }
        let p = normalize(path)
        let h = normalize(home)
        if p == "/" || p == h || isAncestor(p, of: h) || ["/system/volumes", "/system/volumes/data", "/system/volumes/data/users"].contains(p) {
            return .rejected("Choose a folder, not the whole disk, a folder of homes or your home folder.")
        }
        for (root, name) in [(h + "/desktop", "Desktop"), (h + "/documents", "Documents"),
                             (h + "/library", "Library or iCloud Drive")] where p == root || isAncestor(root, of: p) {
            return .rejected("\(name) is protected by macOS; PlatyNotch would have to ask again at every launch.")
        }
        for root in ["/volumes", "/network", "/net", "/system/volumes/data/volumes"] where p == root || isAncestor(root, of: p) {
            return .rejected("External, removable and network drives are protected by macOS; choose a folder on this Mac.")
        }
        for name in ["pictures", "movies", "music"] where p == h + "/" + name {
            return .rejected("Choose a folder inside \(name.capitalized), not the whole folder.")
        }
        if let other = homeFolder(of: p), other != h, other != "/users/shared" {
            return .rejected("That is in another user's home folder.")
        }
        return .allowed
    }

    private static func isAncestor(_ a: String, of b: String) -> Bool {
        b.hasPrefix(a == "/" ? "/" : a + "/") && a != b
    }

    /// "/users/name" for a (normalized) path under /Users/name.
    private static func homeFolder(of p: String) -> String? {
        for base in ["/users/"] where p.hasPrefix(base) {
            let name = p.dropFirst(base.count).split(separator: "/").first.map(String.init) ?? ""
            return name.isEmpty ? nil : "/users/" + name
        }
        return nil
    }

    /// Lowercased (APFS is case-insensitive by default); `.`, `..` and repeated slashes
    /// resolved textually (no file-system access); the Data volume's firmlink prefix removed.
    static func normalize(_ s: String) -> String {
        var parts: [Substring] = []
        for part in s.lowercased().split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        var p = "/" + parts.joined(separator: "/")
        if p.hasPrefix("/system/volumes/data/users/") { p = String(p.dropFirst("/system/volumes/data".count)) }
        return p
    }
}
