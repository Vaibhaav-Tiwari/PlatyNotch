import Darwin
import Foundation

/// The quick note: one line, `- HH:mm text`, appended to today's daily note in the vault
/// (`<daily folder>/YYYY-MM-DD.md`) or, with no vault, to `notes.noindex/notes.md`.
///
/// Appending never rewrites a file: it opens it with `O_APPEND` (never following a link)
/// and writes the new line at the end, after a line break when the file does not end with
/// one, in the line ending the file already uses. The daily folder is never created: when
/// it is missing the append fails and says so. Only today's note itself may be created.
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
        guard let clean = cleanFolder(folder) else { return nil }
        var url = vault
        if !clean.isEmpty { url = url.appendingPathComponent(clean, isDirectory: true) }
        return url.appendingPathComponent(dailyNoteName(for: date, calendar: calendar))
    }

    public enum AppendResult: Equatable, Sendable {
        case appended
        case failed(String)
    }

    /// Appends `entry` as one line to `url`. `createMode`: make the file (in a folder that
    /// exists) with these permissions when missing; nil appends only to an existing file.
    public static func append(_ entry: String, to url: URL, createMode: mode_t?) -> AppendResult {
        let path = url.path
        let folder = url.deletingLastPathComponent().path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            return .failed("The folder \((folder as NSString).lastPathComponent) does not exist.")
        }
        var flags = O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        if createMode != nil { flags |= O_CREAT }
        let fd = open(path, flags, createMode ?? 0o600)
        guard fd >= 0 else {
            switch errno {
            case EACCES, EPERM, EROFS: return .failed("The note is read-only.")
            case ELOOP: return .failed("The note is a link; PlatyNotch does not write through links.")
            case ENOENT: return .failed("The note does not exist.")
            default: return .failed("The note could not be opened.")
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return .failed("The note is not a plain file.") }
        // The file's own line ending (from its start) and whether it ends with a break.
        var head = [UInt8](repeating: 0, count: Int(min(st.st_size, 65_536)))
        let got = head.isEmpty ? 0 : pread(fd, &head, head.count, 0)
        if got > 0 { head = Array(head.prefix(got)) } else { head = [] }
        let ending = MarkdownTasks.lineEnding(of: head)
        var last: UInt8 = 0
        if st.st_size > 0 { _ = pread(fd, &last, 1, st.st_size - 1) }
        var text = ""
        if st.st_size > 0, last != MarkdownTasks.lf, last != MarkdownTasks.cr { text += ending }
        text += entry + ending
        let data = Array(text.utf8)
        let wrote = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == data.count else { return .failed("The note could not be written.") }
        return .appended
    }

    /// Appends to the fallback file in `folder` (`CorePaths.notes()`): the folder is made
    /// 0700 and marked private, the file 0600.
    public static func appendToFallback(_ entry: String, folder: URL) -> AppendResult {
        guard PrivateFolder.ensure(folder) else { return .failed("The notes folder could not be made.") }
        return append(entry, to: folder.appendingPathComponent(fallbackName), createMode: 0o600)
    }
}
