import AppKit
import CoreServices
import Darwin
import Foundation
import os
import PlatyNotchKit

/// One FSEvents item in the vault: its path and what macOS says about it.
struct VaultEvent: Equatable, Sendable {
    let path: String
    /// A folder (created, renamed, removed): its notes are found by a full walk.
    let isDirectory: Bool
    /// Events were coalesced or dropped below this path, or the vault itself moved: walk it all.
    let mustScan: Bool
}

/// Watches `root` and hands coalesced batches of events to `onEvents` on the main thread;
/// nil when it could not start. Tests pass a fake.
typealias VaultWatcherFactory = @MainActor (_ root: String,
                                           _ onEvents: @escaping @MainActor ([VaultEvent]) -> Void) -> FolderWatching?

/// What one batch of events asks for: a full walk, or a fresh look at these notes only.
struct VaultRescan: Equatable, Sendable {
    var full = false
    var paths: Set<String> = []

    var isEmpty: Bool { !full && paths.isEmpty }

    mutating func merge(_ other: VaultRescan) {
        full = full || other.full
        paths.formUnion(other.paths)
    }

    /// Pure. Below `root` and outside dot folders only (Obsidian rewrites
    /// `.obsidian/workspace.json` all the time): a note's event looks at that note, a
    /// folder's (or a dropped batch) walks the vault, anything else is ignored.
    static func plan(_ events: [VaultEvent], root: String) -> VaultRescan {
        var out = VaultRescan()
        let base = root.hasSuffix("/") ? root : root + "/"
        for e in events {
            if e.mustScan {
                out.full = true
                continue
            }
            guard e.path.hasPrefix(base), !VaultScanner.isHidden(e.path, under: root) else { continue }
            if e.isDirectory {
                out.full = true
            } else if (e.path as NSString).pathExtension.lowercased() == "md" {
                out.paths.insert(e.path)
            }
        }
        return out
    }
}

/// Everything the notes widget does to the disk and the system, behind one seam (tests
/// pass fakes for the grant, the bookmark and the watch, and real files in a temp folder).
///
/// The vault is chosen only with `NSOpenPanel` from the widget's settings button and kept
/// as a plain bookmark (`FileBookmarks`; the app is not sandboxed), made only once macOS
/// let PlatyNotch list it. It may be in Documents or iCloud Drive (an explicit choice,
/// R18): listing it once, from the button, is what shows macOS's Files and Folders prompt,
/// and the grant is stamped with this build's identity (`GrantStamp`), so after a rebuild
/// the vault stays off until "Turn On Again".
struct VaultServices {
    /// This build's code identity (`CodeIdentity`), saved with the grant.
    var identity: @MainActor () -> String
    var bookmarks: ShelfBookmarks
    /// Lists the folder once (the macOS prompt), from a button only. May wait for the answer.
    var probe: @MainActor (URL) async -> Bool
    /// `realpath` of the vault folder itself (FSEvents reports real paths).
    var resolve: @Sendable (String) -> String
    var watch: VaultWatcherFactory
    /// Batches of events within this of the first make one rescan.
    var rescanDelay: Duration
    /// While the tile shows, a full walk this often (new notes in the 30-day window, old ones out).
    var periodicRescan: Duration
    /// The walk (names, dates and sizes only). Runs off the main thread.
    var scan: @Sendable (URL, Date) -> VaultScan
    /// One note stat'ed afresh (an event's path). Runs off the main thread.
    var stat: @Sendable (String, String, Date) -> ScannedNote?
    /// Reads one note for its tasks. Runs off the main thread.
    var read: @Sendable (String) -> Data?
    /// The guarded write-back (`TaskFileWriter`). Run on `writer`.
    var toggle: @Sendable (MarkdownTask) -> TaskWriteResult
    /// `QuickNote.append(_:root:path:createMode:)` / `appendToFallback`. Run on `writer`.
    var append: @Sendable (String, URL, String, mode_t?) -> QuickNote.AppendResult
    var appendFallback: @Sendable (String, URL) -> QuickNote.AppendResult
    /// Every write, one at a time.
    var writer: NoteWriter
    /// `CorePaths.notes()`: where quick notes go with no vault.
    var fallbackFolder: URL
    var clock: @Sendable () -> Date
    var calendar: Calendar

    static func system() -> VaultServices {
        VaultServices(identity: { CodeIdentity.current }, bookmarks: FileBookmarks(),
                      probe: { await VaultAccess.probe($0) }, resolve: { VaultAccess.canonical($0) },
                      watch: { VaultEventsWatcher.make(root: $0, onEvents: $1) },
                      rescanDelay: .seconds(2), periodicRescan: .seconds(300),
                      scan: { VaultScanner.scan(root: $0, now: $1) },
                      stat: { VaultScanner.note(at: $0, root: $1, now: $2) },
                      read: { VaultAccess.readNote($0) },
                      toggle: { TaskFileWriter.toggle($0) },
                      append: { QuickNote.append($0, root: $1, path: $2, createMode: $3) },
                      appendFallback: { QuickNote.appendToFallback($0, folder: $1) },
                      writer: NoteWriter(), fallbackFolder: CorePaths.notes(), clock: { Date() }, calendar: .current)
    }

    /// Touches nothing: no grant, no watch, no files (smoke runs).
    static var none: VaultServices {
        VaultServices(identity: { CodeIdentity.unsigned }, bookmarks: NoBookmarks(), probe: { _ in false },
                      resolve: { $0 }, watch: { _, _ in nil }, rescanDelay: .seconds(2), periodicRescan: .seconds(300),
                      scan: { _, _ in VaultScan() }, stat: { _, _, _ in nil }, read: { _ in nil },
                      toggle: { _ in .failed("Not available.") }, append: { _, _, _, _ in .failed("Not available.") },
                      appendFallback: { _, _ in .failed("Not available.") }, writer: NoteWriter(),
                      fallbackFolder: URL(fileURLWithPath: "/nonexistent"), clock: { Date() }, calendar: .current)
    }
}

/// Bookmarks that are never made or resolved (smoke runs).
struct NoBookmarks: ShelfBookmarks {
    func make(_ url: URL) -> Data? { nil }
    func resolve(_ data: Data) -> (url: URL, isStale: Bool)? { nil }
}

/// One FSEvents stream on the vault with file-level events and their flags, coalesced by
/// macOS for `latency`. Only paths and flags: nothing is read here.
final class VaultEventsWatcher: FolderWatching {
    static let latency: CFTimeInterval = 1.0
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "notes")

    private final class Box: @unchecked Sendable {
        var onEvents: (@MainActor ([VaultEvent]) -> Void)?
        init(_ onEvents: @escaping @MainActor ([VaultEvent]) -> Void) { self.onEvents = onEvents }
    }

    nonisolated(unsafe) private var stream: FSEventStreamRef?
    private var box: Box?

    private init() {}

    static func make(root: String, onEvents: @escaping @MainActor ([VaultEvent]) -> Void) -> FolderWatching? {
        let w = VaultEventsWatcher()
        return w.start(root, onEvents) ? w : nil
    }

    private func start(_ root: String, _ onEvents: @escaping @MainActor ([VaultEvent]) -> Void) -> Bool {
        let box = Box(onEvents)
        let retain: CFAllocatorRetainCallBack = { info in
            guard let info else { return nil }
            _ = Unmanaged<Box>.fromOpaque(info).retain()
            return info
        }
        let release: CFAllocatorReleaseCallBack = { info in
            guard let info else { return }
            Unmanaged<Box>.fromOpaque(info).release()
        }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: retain, release: release, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            let scanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                                   | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
            let dirFlag = UInt32(kFSEventStreamEventFlagItemIsDir)
            let fileFlag = UInt32(kFSEventStreamEventFlagItemIsFile)
            var events: [VaultEvent] = []
            for i in 0..<min(count, list.count) {
                let f = flags[i]
                // Neither file nor folder (a plain directory-level event): treat as a folder.
                let isDir = f & dirFlag != 0 || f & fileFlag == 0
                events.append(VaultEvent(path: list[i], isDirectory: isDir, mustScan: f & scanFlags != 0))
            }
            guard !events.isEmpty else { return }
            MainActor.assumeIsolated { box.onEvents?(events) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagIgnoreSelf | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [root] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                          FSEventStreamCreateFlags(flags)) else {
            Self.log.error("could not create the vault FSEvents stream")
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        self.box = box
        return true
    }

    func stop() {
        box?.onEvents = nil
        box = nil
        guard let s = stream else { return }
        stream = nil
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
    }

    deinit {
        guard let s = stream else { return }
        nonisolated(unsafe) let ref = s
        DispatchQueue.main.async {
            FSEventStreamStop(ref)
            FSEventStreamInvalidate(ref)
            FSEventStreamRelease(ref)
        }
    }
}

enum VaultAccess {
    /// The settings button's folder picker. Not modal (C1): `begin`, like Shelf's Locate…,
    /// so an approval arriving while it is open stays clickable. It is opened from the
    /// Settings window, which already made PlatyNotch the active app, so it never activates
    /// the app itself. `chosen` runs only when the user picks a folder.
    @MainActor
    static func chooseFolder(_ chosen: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Use as Vault"
        panel.message = "Choose your Obsidian vault (or any folder of Markdown notes)."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { chosen(url) }
        }
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
}
