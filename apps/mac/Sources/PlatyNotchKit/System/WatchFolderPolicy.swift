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
        let p = normalize(path)
        let h = normalize(home)
        guard p.hasPrefix("/") else { return .rejected("Choose a folder on this Mac.") }
        if p == "/" || p == h { return .rejected("Choose a folder, not the whole disk or your home folder.") }
        let guarded: [(String, String)] = [
            (h + "/desktop", "Desktop"), (h + "/documents", "Documents"), (h + "/library", "Library or iCloud Drive"),
        ]
        for (root, name) in guarded where p == root || p.hasPrefix(root + "/") {
            return .rejected("\(name) is protected by macOS; PlatyNotch would have to ask again at every launch.")
        }
        for root in ["/volumes", "/network", "/net", "/system/volumes/data/volumes"] where p == root || p.hasPrefix(root + "/") {
            return .rejected("External, removable and network drives are protected by macOS; choose a folder on this Mac.")
        }
        if let other = homeFolder(of: p), other != h, other != "/users/shared" {
            return .rejected("That is in another user's home folder.")
        }
        return .allowed
    }

    /// "/users/name" for a (normalized) path under /Users/name.
    private static func homeFolder(of p: String) -> String? {
        for base in ["/users/"] where p.hasPrefix(base) {
            let name = p.dropFirst(base.count).split(separator: "/").first.map(String.init) ?? ""
            return name.isEmpty ? nil : "/users/" + name
        }
        return nil
    }

    /// Lowercased (APFS is case-insensitive by default), no trailing slash, the Data
    /// volume's firmlink prefix removed.
    private static func normalize(_ s: String) -> String {
        var p = s.lowercased()
        if p.hasPrefix("/system/volumes/data/users/") { p = String(p.dropFirst("/System/Volumes/Data".count)) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
