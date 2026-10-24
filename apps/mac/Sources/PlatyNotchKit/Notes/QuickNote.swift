import Darwin
import Foundation

/// The quick note: one line, `- HH:mm text`, appended to today's daily note in the vault
/// (`<daily folder>/YYYY-MM-DD.md`) or, with no vault, to `notes.noindex/notes.md`.
///
/// Appending never rewrites a file: it opens it with `O_APPEND` (never following a link)
/// and writes the new line at the end, after a line break when the file does not end with
/// one, in the line ending the file already uses. No folder is ever created, and today's
/// note only when the user turned that on (Obsidian makes it from its template otherwise).
public enum QuickNote {
    public static let defaultDailyFolder = "Daily"
    public static let fallbackName = "notes.md"
    /// Longer notes are cut to this many characters.
    public static let maxLength = 2_000

    /// `- HH:mm text` (24-hour, local time); line breaks become spaces. nil for blank text.
    public static func entry(_ text: String, at date: Date, calendar: Calendar = .current) -> String? {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty else { return nil }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        return "- " + time + " " + String(flat.prefix(maxLength))
    }

    /// `YYYY-MM-DD.md` for `date` in `calendar`.
    public static func dailyNoteName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d.md", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The daily folder as a clean path inside the vault ("" is the vault itself), or nil
    /// when it would leave the vault or go into a hidden folder (`..`, `/…`, `.obsidian`).
    public static func cleanFolder(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") { return nil }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for p in parts where p.isEmpty || p.hasPrefix(".") || p.contains("\0") { return nil }
        return parts.joined(separator: "/")
    }

    /// Today's daily note in `vault`, or nil when `folder` is not a clean folder.
    public static func dailyNote(vault: URL, folder: String, date: Date, calendar: Calendar = .current) -> URL? {
        guard let rel = dailyNotePath(folder: folder, date: date, calendar: calendar) else { return nil }
        return vault.appendingPathComponent(rel)
    }

    /// `<folder>/YYYY-MM-DD.md` inside the vault, or nil when `folder` is not a clean folder.
    public static func dailyNotePath(folder: String, date: Date, calendar: Calendar = .current) -> String? {
        guard let clean = cleanFolder(folder) else { return nil }
        let name = dailyNoteName(for: date, calendar: calendar)
        return clean.isEmpty ? name : clean + "/" + name
    }

    public enum AppendResult: Equatable, Sendable {
        case appended
        /// The note does not exist and was not to be made (today's note: Obsidian makes it
        /// from its template).
        case noNote
        case failed(String)
    }

    /// Shown for `noNote` on today's note.
    public static let noDailyNote = "Today's note doesn't exist yet — open it in Obsidian first."

    /// Appends `entry` as one line to `url` (the folder is `url`'s own; see `append(_:root:path:createMode:)`).
    public static func append(_ entry: String, to url: URL, createMode: mode_t? = nil) -> AppendResult {
        append(entry, root: url.deletingLastPathComponent(), path: url.lastPathComponent, createMode: createMode)
    }

    /// Appends `entry` as one line to `path` (relative, `/`-separated) inside `root`. Every
    /// folder on the way and the note itself are opened with `O_NOFOLLOW` from `root`
    /// (`openat`), so a linked folder or note never leads out of the vault; no folder is
    /// ever made. `createMode`: make the note with these permissions when missing; nil
    /// returns `noNote` instead. A note that is not UTF-8 text or over
    /// `TaskFileWriter.maxBytes` is refused.
    public static func append(_ entry: String, root: URL, path: String, createMode: mode_t? = nil) -> AppendResult {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            return .failed("That note is not inside the folder.")
        }
        var dir = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return .failed("The folder could not be opened.") }
        for part in parts.dropLast() {
            let next = openat(dir, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let err = errno
            close(dir)
            guard next >= 0 else {
                if err == ENOENT { return .failed("The folder \(part) does not exist.") }
                return .failed("The folder \(part) is a link or not a folder; PlatyNotch writes only inside the vault.")
            }
            dir = next
        }
        defer { close(dir) }
        var flags = O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        if createMode != nil { flags |= O_CREAT }
        let fd = openat(dir, name, flags, createMode ?? 0o600)
        guard fd >= 0 else {
            switch errno {
            case ENOENT: return .noNote
            case EACCES, EPERM, EROFS: return .failed("The note is read-only.")
            case ELOOP: return .failed("The note is a link; PlatyNotch does not write through links.")
            default: return .failed("The note could not be opened.")
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .failed("The note is not a plain file.") }
        guard st.st_size <= off_t(TaskFileWriter.maxBytes) else { return .failed("The note is too large to add to here.") }
        guard let existing = readAll(fd, size: Int(st.st_size)) else { return .failed("The note could not be read.") }
        guard TaskFileWriter.isText(existing) else { return .failed("The note is not UTF-8 text, so nothing was added.") }
        let ending = MarkdownTasks.lineEnding(of: existing)
        var text = ""
        if let last = existing.last, last != MarkdownTasks.lf, last != MarkdownTasks.cr { text += ending }
        text += entry + ending
        guard writeAll(fd, Array(text.utf8)) else { return .failed("The note could not be written.") }
        return .appended
    }

    /// The whole file from offset 0 (`pread`, retried on EINTR and short reads).
    static func readAll(_ fd: Int32, size: Int) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: size)
        var got = 0
        while got < size {
            let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, size - got, off_t(got)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            got += n
        }
        return got == size ? buf : nil
    }

    /// Writes every byte (retried on EINTR and short writes).
    static func writeAll(_ fd: Int32, _ data: [UInt8]) -> Bool {
        var done = 0
        while done < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + done, data.count - done) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            done += n
        }
        return true
    }

    /// Appends to the fallback file in `folder` (`CorePaths.notes()`): the folder is made
    /// 0700 and marked private, the file 0600.
    public static func appendToFallback(_ entry: String, folder: URL) -> AppendResult {
        guard PrivateFolder.ensure(folder) else { return .failed("The notes folder could not be made.") }
        return append(entry, root: folder, path: fallbackName, createMode: 0o600)
    }
}
