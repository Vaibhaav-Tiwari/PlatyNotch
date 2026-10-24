import Foundation

/// Keeps a folder of private copies (clipboard history, the shelf) out of Time Machine and
/// Spotlight: `isExcludedFromBackup` and a `.metadata_never_index` file. Applied when the
/// folder is made and again at each start, for folders made before this existed.
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
}
