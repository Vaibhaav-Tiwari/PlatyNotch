import Darwin
import Foundation

/// What ticking a task in its note did.
public enum TaskWriteResult: Equatable, Sendable {
    /// Written: the task as it reads now.
    case toggled(MarkdownTask)
    /// The note changed since it was read and the line no longer reads the same; exactly
    /// one task elsewhere in the note reads exactly as the old line did. Nothing was
    /// written: ask the user, then toggle this one (which checks again).
    case moved(MarkdownTask)
    /// The note changed and the task could not be found again: nothing was written. The
    /// note's tasks as it reads now.
    case changed([MarkdownTask])
    /// The note is read-only (permissions or a locked file): nothing was written.
    case readOnly
    /// Nothing was written, and why (for the tile).
    case failed(String)
}

/// Ticks a task inside the user's own note (R18). Data safety first:
/// - the note is read again and the task's line must still read exactly as it did when it
///   was parsed (`MarkdownTask.raw`) and be a task in the same state; otherwise nothing is
///   written (`moved` / `changed`);
/// - exactly one byte changes (the checkbox), so line endings, a BOM, frontmatter and every
///   other line are kept byte for byte;
/// - the new contents are written to a file in the system's item-replacement folder (never
///   in the vault) with the note's permissions and extended attributes, and swapped in with
///   `FileManager.replaceItemAt` (atomic: Obsidian or iCloud never see half a file);
/// - just before the swap the note is read once more, and an edit made meanwhile wins;
/// - a symlink, a hard-linked file, a locked or read-only file, a file that is not valid
///   UTF-8 or larger than `maxBytes` is never written.
public enum TaskFileWriter {
    public static let maxBytes = 2_000_000

    public static func toggle(_ task: MarkdownTask, fileManager: FileManager = .default,
                              calendar: Calendar = .current,
                              beforeSwap: (() -> Void)? = nil) -> TaskWriteResult {
        let path = task.file
        let url = URL(fileURLWithPath: path)
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
        guard String(bytes: data, encoding: .utf8) != nil else { return .failed("The note is not UTF-8 text.") }

        switch check(task, bytes: bytes, calendar: calendar) {
        case .stale(let result): return result
        case .ok(let offset, let doneNow):
            var out = bytes
            out[offset] = doneNow ? MarkdownTasks.space : MarkdownTasks.lowerX
            guard differsInOneByte(bytes, out) else { return .failed("Nothing to change.") }
            do {
                let tmpDir = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: url, create: true)
                defer { try? fileManager.removeItem(at: tmpDir) }
                let tmp = tmpDir.appendingPathComponent("note.md")
                guard fileManager.createFile(atPath: tmp.path, contents: Data(out),
                                             attributes: [.posixPermissions: 0o600]) else {
                    return .failed("The change could not be written.")
                }
                guard chmod(tmp.path, st.st_mode & 0o7777) == 0 else { return .failed("The change could not be written.") }
                copyExtendedAttributes(from: path, to: tmp.path)
                beforeSwap?()
                // An edit that landed after the first read wins.
                guard let again = fileManager.contents(atPath: path), again == data else {
                    let now = fileManager.contents(atPath: path).map { [UInt8]($0) } ?? []
                    if case .stale(let result) = check(task, bytes: now, calendar: calendar) { return result }
                    return .changed(MarkdownTasks.parse(bytes: now, file: path, calendar: calendar))
                }
                var lst = stat()
                guard lstat(path, &lst) == 0, (lst.st_mode & S_IFMT) == S_IFREG, lst.st_ino == st.st_ino else {
                    return .failed("The note was moved or replaced.")
                }
                _ = try fileManager.replaceItemAt(url, withItemAt: tmp, backupItemName: nil, options: [])
            } catch {
                return .failed("The change could not be written.")
            }
            guard let written = MarkdownTasks.locate(out, line: task.line, file: path, calendar: calendar) else {
                return .failed("The change could not be checked.")
            }
            return .toggled(written.task)
        }
    }

    private enum Check {
        case ok(offset: Int, done: Bool)
        case stale(TaskWriteResult)
    }

    /// The task's line must read exactly as when it was parsed and still be a task in the
    /// same state; else the note is parsed again and the old line looked for.
    private static func check(_ task: MarkdownTask, bytes: [UInt8], calendar: Calendar) -> Check {
        if let hit = MarkdownTasks.locate(bytes, line: task.line, file: task.file, calendar: calendar),
           hit.task.raw == task.raw, hit.task.done == task.done {
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
        let size = listxattr(source, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(source, &names, size, XATTR_NOFOLLOW) == size else { return }
        let list = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        for name in list {
            let n = getxattr(source, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard n >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: n)
            guard getxattr(source, name, &value, n, 0, XATTR_NOFOLLOW) == n else { continue }
            _ = setxattr(target, name, value, n, 0, XATTR_NOFOLLOW)
        }
    }

    /// The extended attributes' names (tests).
    public static func extendedAttributeNames(_ path: String) -> [String] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [] }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(path, &names, size, XATTR_NOFOLLOW) == size else { return [] }
        return names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
    }
}
