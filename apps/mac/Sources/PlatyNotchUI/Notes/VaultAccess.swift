import AppKit
import Darwin
import Foundation
import PlatyNotchKit

/// Everything the notes widget does to the disk and the system, behind one seam (tests
/// pass fakes for the grant, the bookmark and the watch, and real files in a temp folder).
///
/// The vault is chosen only with `NSOpenPanel` from the widget's settings button and kept
/// as a plain bookmark (`FileBookmarks`; the app is not sandboxed). It may be in Documents
/// or iCloud Drive (an explicit choice, R18): listing it once, from the button, is what
/// shows macOS's Files and Folders prompt, and the grant is stamped with this build's
/// identity (`GrantStamp`), so after a rebuild the vault stays off until "Turn On Again".
struct VaultServices {
    /// This build's code identity (`CodeIdentity`), saved with the grant.
    var identity: @MainActor () -> String
    var bookmarks: ShelfBookmarks
    /// Lists the folder once (the macOS prompt), from a button only. May wait for the answer.
    var probe: @MainActor (URL) async -> Bool
    /// `realpath` of the vault folder itself (FSEvents reports real paths).
    var resolve: @Sendable (String) -> String
    var watch: FolderWatcherFactory
    /// The walk (names, dates and sizes only). Runs off the main thread.
    var scan: @Sendable (URL, Date) -> VaultScan
    /// Reads one note for its tasks. Runs off the main thread.
    var read: @Sendable (String) -> Data?
    /// The guarded write-back (`TaskFileWriter`). Runs off the main thread.
    var toggle: @Sendable (MarkdownTask) -> TaskWriteResult
    /// `QuickNote.append` / `appendToFallback`. Run off the main thread.
    var append: @Sendable (String, URL, mode_t?) -> QuickNote.AppendResult
    var appendFallback: @Sendable (String, URL) -> QuickNote.AppendResult
    /// `CorePaths.notes()`: where quick notes go with no vault.
    var fallbackFolder: URL
    var clock: @Sendable () -> Date
    var calendar: Calendar

    static func system() -> VaultServices {
        VaultServices(identity: { CodeIdentity.current }, bookmarks: FileBookmarks(),
                      probe: { await VaultAccess.probe($0) }, resolve: { VaultAccess.canonical($0) },
                      watch: { FSEventsWatcher.make(folders: $0, onPaths: $1) },
                      scan: { VaultScanner.scan(root: $0, now: $1) },
                      read: { VaultAccess.readNote($0) },
                      toggle: { TaskFileWriter.toggle($0) },
                      append: { QuickNote.append($0, to: $1, createMode: $2) },
                      appendFallback: { QuickNote.appendToFallback($0, folder: $1) },
                      fallbackFolder: CorePaths.notes(), clock: { Date() }, calendar: .current)
    }

    /// Touches nothing: no grant, no watch, no files (smoke runs).
    static var none: VaultServices {
        VaultServices(identity: { CodeIdentity.unsigned }, bookmarks: NoBookmarks(), probe: { _ in false },
                      resolve: { $0 }, watch: { _, _ in nil }, scan: { _, _ in VaultScan() }, read: { _ in nil },
                      toggle: { _ in .failed("Not available.") }, append: { _, _, _ in .failed("Not available.") },
                      appendFallback: { _, _ in .failed("Not available.") },
                      fallbackFolder: URL(fileURLWithPath: "/nonexistent"), clock: { Date() }, calendar: .current)
    }
}

/// Bookmarks that are never made or resolved (smoke runs).
struct NoBookmarks: ShelfBookmarks {
    func make(_ url: URL) -> Data? { nil }
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? { nil }
}

enum VaultAccess {
    /// The settings button's folder picker. Activates the app first: PlatyNotch is an
    /// accessory app and the panel would otherwise open behind other windows.
    @MainActor
    static func chooseFolder() -> URL? {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use as Vault"
        panel.message = "Choose your Obsidian vault (or any folder of Markdown notes)."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Lists the folder's names once, off the main thread (it waits while macOS asks).
    nonisolated static func probe(_ folder: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil
        }.value
    }

    nonisolated static func canonical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// A note's bytes, never through a link and never one over `VaultScanner.maxFileBytes`.
    nonisolated static func readNote(_ path: String) -> Data? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size <= off_t(VaultScanner.maxFileBytes) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// FSEvents paths worth a rescan: below `root`, not in a dot folder (Obsidian rewrites
    /// `.obsidian/workspace.json` all the time) and a note or a folder (no extension).
    nonisolated static func relevant(_ paths: [String], root: String) -> Bool {
        paths.contains { p in
            let base = root.hasSuffix("/") ? root : root + "/"
            guard p == root || p.hasPrefix(base) else { return false }
            guard !VaultScanner.isHidden(p, under: root) else { return false }
            let ext = (p as NSString).pathExtension.lowercased()
            return ext == "md" || ext.isEmpty
        }
    }
}
