import AppKit
import Foundation
import PlatyNotchKit

/// What clipboard history writes to the pasteboard (a paste from the picker or tile).
enum ClipContent: Equatable {
    case text(String)
    case url(URL)
    case files([URL])
    case png(Data)
}

/// The pasteboard as clipboard history uses it: a seam, so tests and smoke runs never
/// read or write the real system pasteboard.
@MainActor
protocol ClipboardPasteboard: AnyObject {
    /// Cheap; reading it reads no content.
    var changeCount: Int { get }
    var types: [String] { get }
    func string(forType type: String) -> String?
    func data(forType type: String) -> Data?
    func fileURLs() -> [URL]
    /// The first http(s) URL object on the pasteboard.
    func webURL() -> URL?
    /// Replaces the contents (marked as written by PlatyNotch); returns the new change count.
    @discardableResult
    func write(_ content: ClipContent) -> Int
}

/// `NSPasteboard.general` (or another named pasteboard).
@MainActor
final class SystemPasteboard: ClipboardPasteboard {
    private let pb: NSPasteboard
    init(_ pb: NSPasteboard = .general) { self.pb = pb }

    var changeCount: Int { pb.changeCount }
    var types: [String] { (pb.types ?? []).map(\.rawValue) }
    func string(forType type: String) -> String? { pb.string(forType: NSPasteboard.PasteboardType(type)) }
    func data(forType type: String) -> Data? { pb.data(forType: NSPasteboard.PasteboardType(type)) }

    func fileURLs() -> [URL] {
        pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func webURL() -> URL? {
        let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
    }

    func write(_ content: ClipContent) -> Int {
        pb.clearContents()
        switch content {
        case .text(let t): pb.setString(t, forType: .string)
        case .url(let u):
            pb.writeObjects([u as NSURL])
            pb.setString(u.absoluteString, forType: .string)
        case .files(let urls): pb.writeObjects(urls.map { $0 as NSURL })
        case .png(let d): pb.setData(d, forType: .png)
        }
        // nspasteboard.org: who wrote it (also keeps our own write out of history).
        pb.setString(Bundle.main.bundleIdentifier ?? "dev.platynotch.app",
                     forType: NSPasteboard.PasteboardType(ClipFilter.sourceType))
        return pb.changeCount
    }
}

/// Reads and writes nothing (smoke runs and the inert widget).
@MainActor
final class NoPasteboard: ClipboardPasteboard {
    var changeCount: Int { 0 }
    var types: [String] { [] }
    func string(forType type: String) -> String? { nil }
    func data(forType type: String) -> Data? { nil }
    func fileURLs() -> [URL] { [] }
    func webURL() -> URL? { nil }
    func write(_ content: ClipContent) -> Int { 0 }
}

/// The frontmost app (the best guess at who changed the pasteboard, C21) and app
/// activations (event-driven, no polling).
@MainActor
protocol FrontmostApp: AnyObject {
    var bundleID: String? { get }
    var processID: pid_t? { get }
    /// PlatyNotch itself is the active app.
    var weAreActive: Bool { get }
    /// Calls `handler` with each newly activated app's bundle id; the returned closure stops it.
    func observeActivations(_ handler: @escaping @MainActor (String?) -> Void) -> () -> Void
}

@MainActor
final class SystemFrontmostApp: FrontmostApp {
    var bundleID: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    var processID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var weAreActive: Bool { NSApp?.isActive ?? false }

    func observeActivations(_ handler: @escaping @MainActor (String?) -> Void) -> () -> Void {
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                       queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { handler(id) }
        }
        return { center.removeObserver(token) }
    }
}

/// Watches the pasteboard's change count every 0.5 s while running: the one poll the
/// plan allows below 1 s, and only while the clipboard widget is on and not paused
/// (`stop` removes the timer, so a paused or disabled widget reads nothing at all).
///
/// On a change it reads, in order and only while each step passes (`ClipFilter`): the
/// apps (the frontmost one now and every app that was frontmost since the last change,
/// `ClipSourceWindow`, from activation notifications while running), the item's types, its `org.nspasteboard.source`, then the content.
/// What was on the pasteboard before `start` is never recorded, so copies made while
/// paused or off stay out of history.
@MainActor
final class ClipboardWatcher {
    static let interval: TimeInterval = 0.5
    /// An app counts as a possible source if it was frontmost within the poll interval plus
    /// this margin before the change was seen (late timer fires, slow notifications).
    static let sourceMargin: TimeInterval = 1.5
    static var sourceHorizon: TimeInterval { interval + sourceMargin }
    /// Larger image data is not even converted.
    static let maxRawImageBytes = 64 * 1024 * 1024

    enum Capture: Equatable {
        case item(ClipItem.Kind)
        /// PNG or TIFF data, converted and size-checked off the main thread.
        case image(Data, isPNG: Bool)
    }

    typealias Schedule = @MainActor (_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void

    /// A change worth recording, with its (best-effort) source app.
    var onCapture: ((Capture, String?) -> Void)?
    /// Memory's `exclude_apps` (the password-manager floor is always added by the filter).
    var excluded: () -> Set<String> = { [] }

    private let pasteboard: ClipboardPasteboard
    private let frontmost: FrontmostApp
    private let schedule: Schedule
    private let now: () -> Date
    private var cancel: (() -> Void)?
    private var lastChange = 0
    private var window = ClipSourceWindow(current: nil, at: .distantPast)
    private var stopObserving: (() -> Void)?
    /// Pasteboard changes looked at (tests).
    private(set) var changesSeen = 0

    init(pasteboard: ClipboardPasteboard, frontmost: FrontmostApp, schedule: @escaping Schedule = ClipboardWatcher.timer,
         now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.frontmost = frontmost
        self.schedule = schedule
        self.now = now
    }

    var isPolling: Bool { cancel != nil }

    func start() {
        guard cancel == nil else { return }
        lastChange = pasteboard.changeCount
        window.reset(current: frontmost.bundleID, at: now())
        stopObserving = frontmost.observeActivations { [weak self] id in
            guard let self else { return }
            let t = self.now()
            self.window.activated(id, at: t)
            self.window.prune(now: t, horizon: Self.sourceHorizon)
        }
        cancel = schedule(Self.interval) { [weak self] in self?.poll() }
    }

    func stop() {
        cancel?()
        cancel = nil
        stopObserving?()
        stopObserving = nil
    }

    /// Our own write: not a copy to record.
    func ignore(changeCount: Int) {
        lastChange = changeCount
        window.reset(current: frontmost.bundleID, at: now())
    }

    func poll() {
        guard isPolling else { return }
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        changesSeen += 1
        let excluded = excluded()
        let source = frontmost.bundleID
        let seenAt = now()
        let apps = window
        window.reset(current: source, at: seenAt)
        guard apps.allows(current: source, excluded: excluded, at: seenAt, horizon: Self.sourceHorizon) else { return }
        let types = pasteboard.types
        guard !types.isEmpty, ClipFilter.allowsTypes(types) else { return }
        let marked = types.contains(ClipFilter.sourceType) ? pasteboard.string(forType: ClipFilter.sourceType) : nil
        guard ClipFilter.allowsMarkedSource(marked, excluded: excluded) else { return }
        guard let capture = read(types) else { return }
        onCapture?(capture, source)
    }

    /// Files, then a link, then text (a lone http(s) URL is a link), then an image. Text
    /// wins over an image because apps such as Office add a picture of copied text.
    private func read(_ types: [String]) -> Capture? {
        if types.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            let files = pasteboard.fileURLs()
            if !files.isEmpty { return .item(.files(files)) }
        }
        if types.contains(NSPasteboard.PasteboardType.URL.rawValue), let url = pasteboard.webURL() {
            return .item(.url(url))
        }
        if types.contains(NSPasteboard.PasteboardType.string.rawValue),
           let text = pasteboard.string(forType: NSPasteboard.PasteboardType.string.rawValue) {
            if let url = Self.loneWebURL(text) { return .item(.url(url)) }
            return .item(.text(text))
        }
        for (type, png) in [(NSPasteboard.PasteboardType.png, true), (.tiff, false)] where types.contains(type.rawValue) {
            guard let data = pasteboard.data(forType: type.rawValue), data.count <= Self.maxRawImageBytes else { return nil }
            return .image(data, isPNG: png)
        }
        return nil
    }

    static func loneWebURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let url = URL(string: t), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host() != nil else { return nil }
        return url
    }

    /// A main run-loop timer (`.common`, so it also fires during menu and drag tracking),
    /// with tolerance so the system can coalesce wake-ups.
    static func timer(_ interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer.tolerance = interval / 5
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
