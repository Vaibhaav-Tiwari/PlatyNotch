import Foundation

/// File locations shared with the Go core (`core/paths`): `PLATYNOTCH_HOME` and
/// `PLATYNOTCH_SOCKET` redirect them the same way on both sides.
public enum CorePaths {
    public static func home(env: [String: String] = ProcessInfo.processInfo.environment,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let h = env["PLATYNOTCH_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return userHome.appendingPathComponent("Library/Application Support/PlatyNotch")
    }

    public static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment,
                                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let s = env["PLATYNOTCH_SOCKET"], !s.isEmpty { return s }
        return home(env: env, userHome: userHome).appendingPathComponent("notch.sock").path
    }

    public static func coreLog(env: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent("logs/core.log")
    }

    public static func config(env: [String: String] = ProcessInfo.processInfo.environment,
                              userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent("config.json")
    }

    /// The memory database (Go `paths.MemoryDB`).
    public static func memoryDB(env: [String: String] = ProcessInfo.processInfo.environment,
                                userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent("memory.db")
    }

    /// The private folders' names. A `.noindex` suffix keeps Spotlight out of a folder
    /// reliably (a `.metadata_never_index` file below the volume root is not honoured
    /// everywhere); `PrivateFolder.migrateToNoIndex` moves folders made under the old
    /// names (B4).
    public static let shelfName = "shelf.noindex"
    public static let clipboardName = "clipboard.noindex"
    public static let faviconsName = "favicons.noindex"
    /// v0.2 power features' folders (new names, so nothing to migrate).
    public static let basketsName = "baskets.noindex"
    public static let notesName = "notes.noindex"
    /// Old name → new name, for the migration.
    public static let noIndexRenames: [(old: String, new: String)] = [
        ("shelf", shelfName), ("clipboard", clipboardName), ("favicons", faviconsName),
    ]

    /// The file shelf's directory (0700): its index and the copies it owns.
    public static func shelf(env: [String: String] = ProcessInfo.processInfo.environment,
                             userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent(shelfName, isDirectory: true)
    }

    /// Clipboard history's directory (0700): `history.json` (0600) and `images/` (C22).
    public static func clipboard(env: [String: String] = ProcessInfo.processInfo.environment,
                                 userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent(clipboardName, isDirectory: true)
    }

    /// Pinned sites' icons (0700), one file per https origin, kept 30 days (Task 11).
    public static func favicons(env: [String: String] = ProcessInfo.processInfo.environment,
                                userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent(faviconsName, isDirectory: true)
    }

    /// Drag baskets (R4, 0700): one `ShelfStore` folder per basket, `<baskets>/<basket id>/`
    /// (each 0700, made by its store). Not created here: the first basket makes it
    /// (`PrivateFolder.ensure`), so a feature that was never used leaves nothing behind.
    public static func baskets(env: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent(basketsName, isDirectory: true)
    }

    /// The notes folder (0700). Not created here (`PrivateFolder.ensure`, on first use).
    public static func notes(env: [String: String] = ProcessInfo.processInfo.environment,
                             userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent(notesName, isDirectory: true)
    }

    /// The stable hook binary path written into agent configs (Go `paths.HookBinary`):
    /// a symlink the app keeps pointed at its bundled `notch` (see `HookBinaryLink`).
    public static func hookBinary(env: [String: String] = ProcessInfo.processInfo.environment,
                                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent("bin/notch")
    }

    /// `PLATYNOTCH_CORE_BIN`, else `name` next to the running executable
    /// (`Contents/MacOS/notch` in the bundle, `.build/debug/notch` under `swift run`).
    public static func coreBinary(name: String,
                                  env: [String: String] = ProcessInfo.processInfo.environment,
                                  executableURL: URL? = Bundle.main.executableURL) -> URL {
        if let p = env["PLATYNOTCH_CORE_BIN"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let dir = executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        return dir.appendingPathComponent(name)
    }
}
