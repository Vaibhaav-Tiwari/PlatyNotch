import Darwin
import Foundation

/// What ticking a task in its note did.
public enum TaskWriteResult: Equatable, Sendable {
    /// Written: the task as it reads now.
    case toggled(MarkdownTask)
    /// The note changed since it was read and PlatyNotch cannot be sure which line is
    /// meant: the line moved and exactly one task elsewhere reads exactly as the old line
    /// did, or the line still reads the same but the same text is on other lines too.
    /// Nothing was written: ask the user, then toggle this one (which checks again).
    case moved(MarkdownTask)
    /// The note changed and the task could not be found again: nothing was written. The
    /// note's tasks as it reads now.
    case changed([MarkdownTask])
    /// The note is read-only (permissions or a locked file): nothing was written.
    case readOnly
    /// A recurring task (`🔁`): never written; tick it in Obsidian.
    case recurring
    /// Nothing was written, and why (for the tile).
    case failed(String)
}

/// Every write PlatyNotch makes to notes (ticks and quick-note appends) runs on this one
/// serial queue, one after another, never two at once: two ticks in the same note, or a
/// tick and an append, each read the note the other just wrote. Off the main thread.
public final class NoteWriter: Sendable {
    private let queue = DispatchQueue(label: "dev.platynotch.notes.writer", qos: .userInitiated)

    public init() {}

    public func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            queue.async { c.resume(returning: body()) }
        }
    }
}

/// Ticks a task inside the user's own note (R18). Data safety first:
/// - the note is read again and the task's line must still read exactly as it did when it
///   was parsed (`MarkdownTask.raw`) and be a task in the same state; when the note changed
///   since (`noteHash`) and that text is on more than one line, the user is asked first;
///   otherwise nothing is written (`moved` / `changed`);
/// - exactly one byte changes (the checkbox), so line endings, a BOM, frontmatter and every
///   other line are kept byte for byte;
/// - the new contents are written to a file in the system's item-replacement folder (never
///   in the vault) with the note's permissions, group, creation date and extended
///   attributes, then swapped in with `renamex_np(RENAME_SWAP)` (atomic). The file swapped
///   out is compared with what was read: if anything wrote the note meanwhile, the swap is
///   undone and nothing is lost (`changed`). iCloud Drive notes are swapped under an
///   `NSFileCoordinator` (`.forReplacing`);
/// - a symlink, a hard-linked file, a locked or read-only file, a recurring task, a file
///   that is not valid UTF-8 or larger than `maxBytes` is never written.
/// Run it on a `NoteWriter`.
public enum TaskFileWriter {
    public static let maxBytes = 2_000_000

    public static func toggle(_ task: MarkdownTask, fileManager: FileManager = .default,
                              calendar: Calendar = .current,
                              beforeSwap: (() -> Void)? = nil) -> TaskWriteResult {
        if task.isRecurring { return .recurring }
        let path = task.file
        var st = stat()
        guard lstat(path, &st) == 0 else { return .failed("The note is gone.") }
        if (st.st_mode & S_IFMT) == S_IFLNK { return .failed("The note is a link; tick it in your notes app.") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failed("The note is not a plain file.") }
        guard st.st_nlink == 1 else { return .failed("The note has more than one name (a hard link); tick it in your notes app.") }
        let locked = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)
        if st.st_flags & locked != 0 || access(path, W_OK) != 0 { return .readOnly }
        guard st.st_size <= off_t(maxBytes) else { return .failed("The note is too large to change here.") }
        guard let data = fileManager.contents(atPath: path) else { return .failed("The note could not be read.") }
        let bytes = [UInt8](data)
        guard isText(bytes) else { return .failed("The note is not UTF-8 text.") }

        switch check(task, bytes: bytes, calendar: calendar) {
        case .stale(let result): return result
        case .ok(let offset, let doneNow):
            var out = bytes
            out[offset] = doneNow ? MarkdownTasks.space : MarkdownTasks.lowerX
            guard differsInOneByte(bytes, out) else { return .failed("Nothing to change.") }
            let url = URL(fileURLWithPath: path)
            let result = coordinated(url) {
                swapIn(out, original: data, at: url, stat: st, task: task, fileManager: fileManager,
                       calendar: calendar, beforeSwap: beforeSwap)
            }
            guard case .toggled = result else { return result }
            guard let written = MarkdownTasks.locate(out, line: task.line, file: path, calendar: calendar) else {
                return .failed("The change could not be checked.")
            }
            return .toggled(written.task)
        }
    }

    /// Valid UTF-8 with no NUL byte (UTF-16 without a BOM is valid UTF-8 full of NULs).
    public static func isText(_ bytes: [UInt8]) -> Bool {
        !bytes.contains(0) && String(validating: bytes, as: UTF8.self) != nil
    }

    private static func swapIn(_ out: [UInt8], original data: Data, at url: URL, stat st: stat, task: MarkdownTask,
                               fileManager: FileManager, calendar: Calendar, beforeSwap: (() -> Void)?) -> TaskWriteResult {
        let path = url.path
        do {
            let tmpDir = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: url, create: true)
            var keep = false
            defer { if !keep { try? fileManager.removeItem(at: tmpDir) } }
            let tmp = tmpDir.appendingPathComponent("note.md")
            guard fileManager.createFile(atPath: tmp.path, contents: Data(out), attributes: [.posixPermissions: 0o600]) else {
                return .failed("The change could not be written.")
            }
            // The note's group, then its mode (chown can clear set-id bits), else no write.
            guard chown(tmp.path, uid_t.max, st.st_gid) == 0 else { return .failed("The note's group could not be kept.") }
            guard chmod(tmp.path, st.st_mode & 0o7777) == 0 else { return .failed("The note's permissions could not be kept.") }
            copyExtendedAttributes(from: path, to: tmp.path)
            if let created = (try? fileManager.attributesOfItem(atPath: path))?[.creationDate] as? Date {
                try? fileManager.setAttributes([.creationDate: created], ofItemAtPath: tmp.path)
            }
            beforeSwap?()
            var lst = stat()
            guard lstat(path, &lst) == 0, (lst.st_mode & S_IFMT) == S_IFREG, lst.st_nlink == 1 else {
                return .failed("The note was moved or replaced.")
            }
            if renamex_np(tmp.path, path, UInt32(RENAME_SWAP)) == 0 {
                // `tmp` now holds what was at `path`: it must be exactly what was read.
                let swappedOut = fileManager.contents(atPath: tmp.path)
                guard swappedOut == data, lst.st_ino == st.st_ino else {
                    guard renamex_np(tmp.path, path, UInt32(RENAME_SWAP)) == 0 else {
                        keep = true   // never delete the other version
                        return .failed("The note changed while it was being ticked; its other version is in \(tmp.path).")
                    }
                    return stale(task, now: swappedOut ?? Data(), calendar: calendar)
                }
                return .toggled(task)
            }
            // A volume without swap support: check once more, then replace.
            guard let again = fileManager.contents(atPath: path), again == data, lst.st_ino == st.st_ino else {
                return stale(task, now: fileManager.contents(atPath: path) ?? Data(), calendar: calendar)
            }
            _ = try fileManager.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
            return .toggled(task)
        } catch {
            return .failed("The change could not be written.")
        }
    }

    /// The note changed during the write: what to tell the user (never `toggled`).
    private static func stale(_ task: MarkdownTask, now data: Data, calendar: Calendar) -> TaskWriteResult {
        let bytes = [UInt8](data)
        if case .stale(let result) = check(task, bytes: bytes, calendar: calendar) { return result }
        return .changed(MarkdownTasks.parse(bytes: bytes, file: task.file, calendar: calendar))
    }

    /// iCloud Drive notes are replaced under a file coordinator, so the sync daemon sees one change.
    private static func coordinated(_ url: URL, _ body: () -> TaskWriteResult) -> TaskWriteResult {
        guard isUbiquitous(url.path) else { return body() }
        var result: TaskWriteResult = .failed("The note could not be coordinated with iCloud Drive.")
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
            result = body()
            _ = u
        }
        return result
    }

    /// Under `~/Library/Mobile Documents` (iCloud Drive and app containers synced by it).
    public static func isUbiquitous(_ path: String) -> Bool {
        path.contains("/Library/Mobile Documents/")
    }

    private enum Check {
        case ok(offset: Int, done: Bool)
        case stale(TaskWriteResult)
    }

    /// The task's line must read exactly as when it was parsed and still be a task in the
    /// same state; else the note is parsed again and the old line looked for.
    private static func check(_ task: MarkdownTask, bytes: [UInt8], calendar: Calendar) -> Check {
        let changed = task.noteHash == 0 || MarkdownTasks.hash(bytes) != task.noteHash
        if let hit = MarkdownTasks.locate(bytes, line: task.line, file: task.file, calendar: calendar),
           hit.task.raw == task.raw, hit.task.done == task.done {
            if hit.task.isRecurring { return .stale(.recurring) }
            guard changed else { return .ok(offset: hit.offset, done: hit.task.done) }
            // Changed since: the same text on several lines may mean lines moved under it.
            let same = MarkdownTasks.parse(bytes: bytes, file: task.file, calendar: calendar).filter { $0.raw == task.raw }
            if same.count > 1 { return .stale(.moved(hit.task)) }
            return .ok(offset: hit.offset, done: hit.task.done)
        }
        let now = MarkdownTasks.parse(bytes: bytes, file: task.file, calendar: calendar)
        let same = now.filter { $0.raw == task.raw && $0.done == task.done }
        if same.count == 1, let only = same.first { return .stale(.moved(only)) }
        return .stale(.changed(now))
    }

    static func differsInOneByte(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var n = 0
        for i in a.indices where a[i] != b[i] { n += 1 }
        return n == 1
    }

    /// Every extended attribute of `source` set on `target` (best effort; some, such as
    /// `com.apple.provenance`, the system manages itself).
    static func copyExtendedAttributes(from source: String, to target: String) {
        for name in extendedAttributeNames(source) {
            let n = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard n >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: n)
            guard getxattr(source, name, &value, n, 0, XATTR_NOFOLLOW) == n else { continue }
            _ = setxattr(target, name, value, n, 0, XATTR_NOFOLLOW)
        }
    }

    /// The extended attributes' names.
    public static func extendedAttributeNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [] }
        return names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
