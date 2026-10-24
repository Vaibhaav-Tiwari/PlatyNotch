import AppKit
import CoreServices
import Foundation
import os
import PlatyNotchKit

/// A running folder watch; `stop` ends it.
@MainActor
public protocol FolderWatching: AnyObject {
    func stop()
}

/// Creates a watch on `folders` that hands coalesced batches of changed paths to `onPaths`
/// on the main thread; nil when it could not start. Tests pass a fake; nothing but
/// `FSEventsWatcher` creates a real FSEvents stream.
public typealias FolderWatcherFactory = @MainActor (_ folders: [String],
                                                   _ onPaths: @escaping @MainActor ([String]) -> Void) -> FolderWatching?

/// Opening and revealing a downloaded file, only from a click. Tests use a fake.
@MainActor
public protocol FileActions: AnyObject {
    func open(_ url: URL)
    func reveal(_ url: URL)
}

final class WorkspaceFileActions: FileActions {
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
}

/// One FSEvents stream on the folders with file-level events, coalesced by macOS for
/// `latency` (one callback per second at most while a download writes). No polling, no
/// directory listing: only the changed paths; the monitor stats those paths, never
/// reads a file.
final class FSEventsWatcher: FolderWatching {
    static let latency: CFTimeInterval = 1.0
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "downloads")

    /// The stream and its context (the stream's `info` points here, unretained; this
    /// object outlives the stream). Its deinit is the safety net if `stop` did not run:
    /// the stream delivers on the main queue, so it is torn down there, whichever thread
    /// the last release happens on.
    private final class Handle: @unchecked Sendable {
        var onPaths: (@MainActor ([String]) -> Void)?
        var stream: FSEventStreamRef?

        func invalidate() {
            guard let s = stream else { return }
            stream = nil
            Self.teardown(s)
        }

        static func teardown(_ s: FSEventStreamRef) {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
        }

        deinit {
            guard let s = stream else { return }
            nonisolated(unsafe) let ref = s
            if Thread.isMainThread {
                Self.teardown(ref)
            } else {
                DispatchQueue.main.async { Self.teardown(ref) }
            }
        }
    }

    private var handle: Handle?

    private init() {}

    static func make(folders: [String], onPaths: @escaping @MainActor ([String]) -> Void) -> FolderWatching? {
        let w = FSEventsWatcher()
        return w.start(folders, onPaths) ? w : nil
    }

    private func start(_ folders: [String], _ onPaths: @escaping @MainActor ([String]) -> Void) -> Bool {
        let h = Handle()
        h.onPaths = onPaths
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(h).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let h = Unmanaged<Handle>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            guard !list.isEmpty else { return }
            // Delivered on the main queue (set below).
            MainActor.assumeIsolated { h.onPaths?(list) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagIgnoreSelf)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, folders as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), Self.latency,
                                          FSEventStreamCreateFlags(flags)) else {
            Self.log.error("could not create the downloads FSEvents stream")
            return false
        }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        h.stream = s
        handle = h
        return true
    }

    func stop() {
        handle?.onPaths = nil
        handle?.invalidate()
        handle = nil
    }
}

/// Follows downloads in the watched folders (`DownloadTracker`) from one folder watch.
/// Small batches are stat'ed on the main thread; larger ones (an unzip, a big copy) off
/// it, in order. While something is in progress, one sleep to the next stale check.
@MainActor
final class DownloadsMonitor {
    /// Up to this many paths to stat, a batch is handled at once on the main thread.
    static let mainThreadStats = 32

    private(set) var tracker: DownloadTracker
    private var watch: FolderWatching?
    private var staleTask: Task<Void, Never>?
    /// The latest off-main batch; later batches wait for it (order matters).
    private var pending: Task<Void, Never>?
    private var generation = 0
    private let stat: @Sendable (String) -> FileStat?
    private let clock: () -> Date
    private let onEvents: @MainActor ([DownloadTracker.Event], DownloadTracker) -> Void

    /// nil when the watch could not start.
    init?(folders: [String], factory: FolderWatcherFactory, stat: @escaping @Sendable (String) -> FileStat?,
          clock: @escaping () -> Date, onEvents: @escaping @MainActor ([DownloadTracker.Event], DownloadTracker) -> Void) {
        tracker = DownloadTracker(folders: folders)
        self.stat = stat
        self.clock = clock
        self.onEvents = onEvents
        weak var me: DownloadsMonitor?
        watch = factory(folders) { paths in me?.batch(paths) }
        guard watch != nil else { return nil }
        me = self
    }

    func stop() {
        watch?.stop()
        watch = nil
        staleTask?.cancel()
        staleTask = nil
        pending?.cancel()
        pending = nil
    }

    /// The latest off-main batch (tests await it).
    var pendingBatch: Task<Void, Never>? { pending }

    private func batch(_ paths: [String]) {
        guard watch != nil else { return }
        let toStat = tracker.pathsToStat(paths)
        if pending == nil, toStat.count <= Self.mainThreadStats {
            finish(paths, stat: stat)
            return
        }
        generation += 1
        let mine = generation
        let previous = pending
        let stat = self.stat
        pending = Task { @MainActor [weak self] in
            await previous?.value
            let stats = await Task.detached(priority: .utility) { Self.statAll(toStat, stat) }.value
            guard let self, !Task.isCancelled, self.watch != nil else { return }
            self.finish(paths, stat: { stats[$0] })
            if self.generation == mine { self.pending = nil }
        }
    }

    private nonisolated static func statAll(_ paths: [String], _ stat: (String) -> FileStat?) -> [String: FileStat] {
        var out: [String: FileStat] = [:]
        for p in paths { if let s = stat(p) { out[p] = s } }
        return out
    }

    private func finish(_ paths: [String], stat: (String) -> FileStat?) {
        let events = tracker.apply(paths: paths, stat: stat, now: clock())
        scheduleStaleCheck()
        if !events.isEmpty { onEvents(events, tracker) }
    }

    /// Ends stale in-progress names (the stale sleep; tests call it directly).
    func pruneStale() {
        let events = tracker.pruneStale(now: clock())
        scheduleStaleCheck()
        if !events.isEmpty { onEvents(events, tracker) }
    }

    private func scheduleStaleCheck() {
        staleTask?.cancel()
        staleTask = nil
        guard let next = tracker.nextStaleCheck else { return }
        let delay = max(1, next.timeIntervalSince(clock()))
        staleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pruneStale()
        }
    }

    /// A `stat` (`attributesOfItem`): type and size, never contents.
    nonisolated static func statFile(_ path: String) -> FileStat? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let isDir = (a[.type] as? FileAttributeType) == .typeDirectory
        return FileStat(isDirectory: isDir, size: (a[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// `~/Downloads` (the real folder, symlinks resolved, as FSEvents reports paths).
    nonisolated static func defaultFolder() -> String {
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return canonical(url.path)
    }

    /// `realpath` of the folder itself (never its contents).
    nonisolated static func canonical(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// The Downloads-folder access check, only from the sub-feature's button: listing the
    /// folder's names (never a file's contents) is what shows the macOS prompt. Off the
    /// main thread: the call waits while the prompt is up.
    nonisolated static func probeAccess(_ folder: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
        }.value
    }
}
