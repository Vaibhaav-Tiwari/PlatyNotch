import Foundation

/// Keeps a folder of private copies (clipboard history, the shelf, favicons) out of Time
/// Machine and Spotlight: `isExcludedFromBackup`, a `.noindex` folder name (`CorePaths`;
/// what Spotlight reliably honours) and, belt and braces, a `.metadata_never_index` file.
/// Applied when the folder is made and again at each start, for folders made before this
/// existed.
public enum PrivateFolder {
    public static let neverIndexName = ".metadata_never_index"

    /// Does nothing when the folder does not exist (it is never created here).
    public static func mark(_ directory: URL, fileManager: FileManager = .default) {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue else { return }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        let marker = directory.appendingPathComponent(neverIndexName)
        if !fileManager.fileExists(atPath: marker.path) {
            fileManager.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    /// Both marks are present (tests, Settings).
    public static func isMarked(_ directory: URL, fileManager: FileManager = .default) -> Bool {
        let excluded = (try? directory.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup ?? false
        return excluded && fileManager.fileExists(atPath: directory.appendingPathComponent(neverIndexName).path)
    }

    /// What `migrateToNoIndex` did with one folder.
    public enum Migration: Equatable, Sendable {
        /// Renamed (one atomic `rename` on the same volume; contents untouched).
        case moved
        /// No folder under the old name: nothing to do.
        case none
        /// Both names exist (an older build ran after the move): neither is touched, the
        /// new one is used, and the old one stays for the user to look at.
        case keptBoth
        /// The rename failed: the old folder is left exactly as it was.
        case failed
    }

    /// Moves `<home>/shelf`, `clipboard` and `favicons` to their `.noindex` names (B4).
    /// Each move is a single `rename(2)`, so a folder is either at its old name or its
    /// new one, never half-moved, and nothing is copied or deleted. Run once at launch,
    /// before any widget opens its folder. Keyed by the old name.
    @discardableResult
    public static func migrateToNoIndex(home: URL, fileManager: FileManager = .default) -> [String: Migration] {
        var out: [String: Migration] = [:]
        for (old, new) in CorePaths.noIndexRenames {
            out[old] = migrate(home.appendingPathComponent(old, isDirectory: true),
                               to: home.appendingPathComponent(new, isDirectory: true), fileManager: fileManager)
        }
        return out
    }

    static func migrate(_ old: URL, to new: URL, fileManager: FileManager) -> Migration {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: old.path, isDirectory: &isDir), isDir.boolValue else { return .none }
        if fileManager.fileExists(atPath: new.path) { return .keptBoth }
        // rename(2) refuses to replace a directory that appeared meanwhile (EEXIST/ENOTEMPTY
        // for a non-empty one; an empty one is replaced, which loses nothing).
        guard rename(old.path, new.path) == 0 else { return .failed }
        return .moved
    }
}
