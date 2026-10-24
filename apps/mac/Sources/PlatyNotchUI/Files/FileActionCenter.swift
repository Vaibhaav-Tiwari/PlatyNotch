import AppKit
import Observation
import os
import PlatyNotchKit
import UniformTypeIdentifiers

/// Where a list's action results go (R11): owned folders of its store, so a result is a
/// new shelf (or basket) item that expires after 7 days unless pinned, and nothing is
/// ever written beside the user's file. The shelf implements it; a basket can too.
@MainActor
protocol FileActionResults: AnyObject {
    /// A fresh owned folder to write a result into.
    func reserveResultFolder() -> (id: UUID, folder: URL)?
    /// Adds `url` (inside the folder reserved for `id`) as an owned item placed right
    /// after `source`. False when refused.
    func addResult(_ url: URL, id: UUID, after source: UUID) -> Bool
    /// A reserved folder that got no result (failure, cancel): deleted.
    func discardResult(_ id: UUID)
    /// Batch rename moved item `id`'s file to `url` (R10: `ShelfStore.relocate`).
    func renamed(_ id: UUID, to url: URL)
    /// The item's own owned folder (`<store>/<id>/`) when the list owns its file; nil for
    /// the user's files, text and links.
    func ownedFolder(of id: UUID) -> URL?
}

/// The "Actions ›" menu of a shelf item, what runs, and the last outcome. One per item
/// list (the shelf; a basket gets its own). Nothing runs until the user picks an action:
/// no timers, no observers. Long actions show on their item and can be cancelled.
@MainActor @Observable
final class FileActionCenter {
    struct Run: Equatable {
        let action: FileAction
        let title: String
    }

    /// One entry of the Actions menu.
    indirect enum Entry: Equatable {
        case action(String, FileAction)
        case submenu(String, [Entry])
        case rename
        case undoRename
    }

    /// How long an outcome line stays.
    static let statusTime: TimeInterval = 6
    @ObservationIgnored private static let log = Logger(subsystem: "dev.platynotch.app", category: "file-actions")

    /// Running actions by the item they work on (one at a time per item).
    private(set) var running: [UUID: Run] = [:]
    /// The last outcome ("Text copied", "Couldn't convert a.heic: …"), for a few seconds.
    private(set) var status: String?
    /// One level of undo for the last Batch rename.
    private(set) var canUndoRename = false

    @ObservationIgnored weak var results: FileActionResults?
    @ObservationIgnored private let engine: FileActionPerforming
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var lastRename: [(item: UUID, step: RenamePlan.Step)] = []
    /// The latest action's task (tests await it).
    @ObservationIgnored private(set) var lastTask: Task<Void, Never>?
    /// Where Copy Text puts its text (tests capture it).
    @ObservationIgnored var copyText: @MainActor (String) -> Void = { text in
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    @ObservationIgnored var removeBackgroundAvailable: Bool
    @ObservationIgnored var writableImageTypes: Set<String>
    /// How Batch rename renames (0 or an errno; never replaces). A seam for tests.
    @ObservationIgnored var renameFile: ShelfStore.FolderRename = FileActionCenter.renameNoReplace
    /// Paths Batch rename never touches (`RenamePolicy`). A seam for tests.
    @ObservationIgnored var isProtected: (URL) -> Bool = { url in
        RenamePolicy.isProtected(url, userHome: FileManager.default.homeDirectoryForCurrentUser, appHome: CorePaths.home())
    }

    init(engine: FileActionPerforming = SystemFileActions(),
         removeBackgroundAvailable: Bool = SystemFileActions.canRemoveBackground,
         writableImageTypes: Set<String> = SystemFileActions.writableImageTypes) {
        self.engine = engine
        self.removeBackgroundAvailable = removeBackgroundAvailable
        self.writableImageTypes = writableImageTypes
    }

    // MARK: - The menu

    /// What a file, folder, text or link is, for choosing actions. Reads the file's type
    /// (metadata only) when the menu opens.
    static func subject(_ item: ShelfItem, url: URL?) -> FileSubject? {
        switch item.kind {
        case .text: return .text
        case .url: return .url
        case .file:
            guard let url else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true { return .folder }
            return .file(values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data)
        }
    }

    /// The Actions menu for `targets` (each with its file's URL; nil for text, links and
    /// missing files). Empty when nothing applies, so the menu is left out.
    func entries(for targets: [(item: ShelfItem, url: URL?)]) -> [Entry] {
        let subjects = targets.compactMap { Self.subject($0.item, url: $0.url) }
        guard subjects.count == targets.count else { return canUndoRename ? [.undoRename] : [] }
        var out: [Entry] = []
        for kind in FileActionMenu.actions(for: subjects, removeBackgroundAvailable: removeBackgroundAvailable) {
            switch kind {
            case .convert:
                if case .file(let type) = subjects[0] {
                    let options = convertEntries(type)
                    if !options.isEmpty { out.append(.submenu("Convert to", options)) }
                }
            case .compressVideo:
                out.append(.submenu("Compress Video", VideoQuality.allCases.map { .action($0.title, .compress($0)) }))
            case .combinePDF: out.append(.action("Combine into PDF", .combinePDF))
            case .zip: out.append(.action(targets.count > 1 ? "Zip Each" : "Zip", .zip))
            case .unzip: out.append(.action("Unzip", .unzip))
            case .copyText: out.append(.action("Copy Text", .copyText))
            case .removeBackground: out.append(.action("Remove Background", .removeBackground))
            case .rename:
                // Hidden when any target is one Batch rename never renames.
                if targets.allSatisfy({ t in t.url.map { canRename(t.item.id, from: $0, to: nil) } ?? false }) {
                    out.append(.rename)
                }
            }
        }
        if canUndoRename { out.append(.undoRename) }
        return out
    }

    private func convertEntries(_ type: UTType) -> [Entry] {
        var out: [Entry] = []
        let family = ConversionMatrix.family(of: type)
        for target in ConversionMatrix.targets(for: type) {
            if family == .image, target != .pdf, !writableImageTypes.contains(target.identifier) { continue }
            if family == .video, target == .mpeg4Movie {
                for codec in VideoCodec.allCases { out.append(.action(codec.title, .convert(target, codec))) }
            } else {
                out.append(.action(Self.title(of: target), .convert(target, nil)))
            }
        }
        return out
    }

    static func title(of type: UTType) -> String {
        switch type {
        case .mpeg4Audio: "M4A (AAC)"
        case .quickTimeMovie: "MOV"
        default: (type.preferredFilenameExtension ?? type.identifier).uppercased()
        }
    }

    // MARK: - Running

    /// Runs `action` on `sources` (resolved, existing files). Combine into PDF makes one
    /// result from all of them (shown on the first); the others run once per item. An
    /// item already busy is skipped.
    func run(_ action: FileAction, on sources: [(item: ShelfItem, url: URL)]) {
        guard !sources.isEmpty else { return }
        if action == .combinePDF {
            start(action, key: sources[0].item.id, urls: sources.map(\.url), name: sources[0].item.title)
        } else {
            for s in sources { start(action, key: s.item.id, urls: [s.url], name: s.item.title) }
        }
    }

    private func start(_ action: FileAction, key: UUID, urls: [URL], name: String) {
        guard running[key] == nil else { return }
        var reserved: (id: UUID, folder: URL)?
        if action.makesFile {
            guard let r = results?.reserveResultFolder() else {
                setStatus("Couldn't \(action.verb) \(name): the shelf can't write to its folder")
                return
            }
            reserved = r
        }
        running[key] = Run(action: action, title: action.progressTitle)
        let engine = self.engine
        let task = Task { [weak self] in
            let outcome: Result<FileActionOutput, Error>
            do {
                let output = try await engine.perform(action, sources: urls, into: reserved?.folder)
                // Cancelled while it finished: the result is not kept (its folder is deleted).
                outcome = Task.isCancelled ? .failure(FileActionError.cancelled) : .success(output)
            } catch {
                outcome = .failure(error)
            }
            self?.finish(action, key: key, name: name, reserved: reserved, outcome: outcome)
        }
        tasks[key] = task
        lastTask = task
    }

    private func finish(_ action: FileAction, key: UUID, name: String, reserved: (id: UUID, folder: URL)?,
                        outcome: Result<FileActionOutput, Error>) {
        running[key] = nil
        tasks[key] = nil
        switch outcome {
        case .success(.text(let text)):
            copyText(text)
            setStatus("Copied the text in \(name)")
        case .success(.file(let url)):
            if let reserved, let results, results.addResult(url, id: reserved.id, after: key) {
                setStatus(nil)
            } else {
                if let reserved { results?.discardResult(reserved.id) }
                setStatus("Couldn't \(action.verb) \(name): the result could not be kept")
            }
        case .failure(let error):
            if let reserved { results?.discardResult(reserved.id) }
            let cancelled = (error as? FileActionError) == .cancelled || error is CancellationError
            if cancelled {
                setStatus("Cancelled")
            } else {
                let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Self.log.error("file action failed: \(why, privacy: .public)")
                NSSound.beep()
                setStatus("Couldn't \(action.verb) \(name): \(why)")
            }
        }
    }

    /// The card's cancel button.
    func cancel(_ item: UUID) {
        tasks[item]?.cancel()
    }

    /// The list stopped (the shelf turned off): everything running is cancelled.
    func cancelAll() {
        for t in tasks.values { t.cancel() }
    }

    func dismissStatus() { setStatus(nil) }

    private func setStatus(_ text: String?) {
        statusTask?.cancel()
        statusTask = nil
        if status != text { status = text }
        guard text != nil else { return }
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.statusTime))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    // MARK: - Batch rename (R10)

    /// The plan for `targets` (files and folders, in list order) under `pattern`.
    static func renamePlan(_ targets: [(item: ShelfItem, url: URL)], pattern: String, date: Date) -> RenamePlan {
        RenamePlan.make(targets.map(\.url), pattern: pattern, date: date) { FileManager.default.fileExists(atPath: $0) }
    }

    /// Renames the user's files as `plan` says (never replacing anything), tells the list
    /// where each went, and keeps one level of undo. Returns how many were renamed and
    /// how many failed.
    @discardableResult
    func rename(_ targets: [(item: ShelfItem, url: URL)], plan: RenamePlan) -> (renamed: Int, failed: Int) {
        let allowed = plan.steps.filter { canRename(targets[$0.index].item.id, from: $0.from, to: $0.to) }
        let done = execute(allowed.map { (targets[$0.index].item.id, $0) })
        lastRename = done
        canUndoRename = !done.isEmpty
        let failed = plan.steps.count - done.count
        if failed > 0 {
            NSSound.beep()
            setStatus("Renamed \(done.count); \(failed) could not be renamed")
        } else {
            setStatus(done.count == 1 ? "Renamed 1 item" : "Renamed \(done.count) items")
        }
        return (done.count, failed)
    }

    /// Whether Batch rename may rename item `id`'s file `from` (to `to`, when known). An
    /// owned copy (an action result, a dropped image) may be renamed within its own owned
    /// folder, even though that is inside PlatyNotch's folder; anything else must not be
    /// protected (`RenamePolicy`).
    func canRename(_ id: UUID, from: URL, to: URL?) -> Bool {
        if let folder = results?.ownedFolder(of: id) {
            let root = folder.standardizedFileURL.path + "/"
            let inside = { (u: URL) in u.standardizedFileURL.path.hasPrefix(root) }
            return inside(from) && (to.map(inside) ?? true)
        }
        return !isProtected(from)
    }

    /// Puts the last Batch rename back (last first). One level only.
    func undoRename() {
        let back = RenamePlan.undo(lastRename.map(\.step)).steps
        let items = lastRename.reversed().map(\.item)
        let done = execute(Array(zip(items, back)))
        lastRename = []
        canUndoRename = false
        setStatus(done.count == back.count ? "Rename undone" : "Undid \(done.count) of \(back.count) renames")
    }

    private func execute(_ steps: [(UUID, RenamePlan.Step)]) -> [(item: UUID, step: RenamePlan.Step)] {
        var done: [(item: UUID, step: RenamePlan.Step)] = []
        for (item, step) in steps {
            guard renameFile(step.from, step.to) == 0 else {
                Self.log.error("rename failed for one item")
                continue
            }
            done.append((item, step))
            results?.renamed(item, to: step.to)
        }
        return done
    }

    /// `renamex_np(RENAME_EXCL)`; for a change of case only (the same file on a
    /// case-insensitive volume), a plain rename after checking the target is that file.
    static let renameNoReplace: ShelfStore.FolderRename = { from, to in
        let a = from.lastPathComponent, b = to.lastPathComponent
        guard a != b, a.lowercased() == b.lowercased(),
              from.deletingLastPathComponent().path == to.deletingLastPathComponent().path else {
            return ShelfStore.renameExclusive(from, to)
        }
        var sa = stat(), sb = stat()
        guard lstat(from.path, &sa) == 0 else { return errno }
        if lstat(to.path, &sb) == 0, sa.st_ino != sb.st_ino || sa.st_dev != sb.st_dev { return EEXIST }
        return Darwin.rename(from.path, to.path) == 0 ? 0 : errno
    }
}
