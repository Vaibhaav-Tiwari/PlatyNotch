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
/// directory listing: only the changed paths; the tracker stats those paths, never
/// reads a file.
final class FSEventsWatcher: FolderWatching {
    static let latency: CFTimeInterval = 1.0
    private static let log = Logger(subsystem: "dev.platynotch.app", category: "downloads")

    private final class Box {
        let onPaths: @MainActor ([String]) -> Void
        init(_ onPaths: @escaping @MainActor ([String]) -> Void) { self.onPaths = onPaths }
    }

    private var stream: FSEventStreamRef?
    private let box: Box

    private init(onPaths: @escaping @MainActor ([String]) -> Void) {
        box = Box(onPaths)
    }

    static func make(folders: [String], onPaths: @escaping @MainActor ([String]) -> Void) -> FolderWatching? {
        let w = FSEventsWatcher(onPaths: onPaths)
        return w.start(folders) ? w : nil
    }

    private func start(_ folders: [String]) -> Bool {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            guard !list.isEmpty else { return }
            // Delivered on the main queue (set below).
            MainActor.assumeIsolated { box.onPaths(list) }
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
        stream = s
        return true
    }

    /// The box (callback context) lives as long as this object; the owner calls `stop`.
    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}

/// Follows downloads in the watched folders (`DownloadTracker`) from one folder watch.
/// While something is in progress, one sleep to the next stale check (no ticking).
@MainActor
final class DownloadsMonitor {
    private(set) var tracker: DownloadTracker
    private var watch: FolderWatching?
    private var staleTask: Task<Void, Never>?
    private let exists: (String) -> Bool
    private let clock: () -> Date
    private let onEvents: @MainActor ([DownloadTracker.Event], DownloadTracker) -> Void

    /// nil when the watch could not start.
    init?(folders: [String], factory: FolderWatcherFactory, exists: @escaping (String) -> Bool,
          clock: @escaping () -> Date, onEvents: @escaping @MainActor ([DownloadTracker.Event], DownloadTracker) -> Void) {
        tracker = DownloadTracker(folders: folders)
        self.exists = exists
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
    }

    private func batch(_ paths: [String]) {
        guard watch != nil else { return }
        let events = tracker.apply(paths: paths, exists: exists, now: clock())
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
