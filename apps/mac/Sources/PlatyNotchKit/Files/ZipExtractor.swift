import Foundation
import zlib

/// PlatyNotch's own unzip (Task 2, fix round 3). `ditto -x` streams local headers and ends
/// a deflate entry where the stream ends, so a crafted archive can make it extract entries
/// the directory never lists. This extractor works only from the central directory that
/// `ZipInspector` checked:
///
/// - only listed entries, stored (0) or raw deflate (8); anything else, and encrypted
///   entries, are refused;
/// - each entry's data is exactly its declared compressed bytes: a deflate stream must end
///   exactly there, the output must be exactly the declared size (it stops the moment it
///   would be more) and its CRC-32 must match;
/// - names are made safe (`\` read as `/`, a leading `/` dropped, `.` and empty parts
///   skipped); any `..` or NUL refuses the archive, as does a repeated name;
/// - files are written to a temporary sibling, then renamed into place (never replacing);
///   folders are made for names ending in `/`; set-user-ID, set-group-ID and sticky bits
///   are dropped, as is group and other write (`setAttributes` ignores the umask), and
///   the owner can always read and write;
/// - links (relative, no `..`, stored, per `ZipInspector`) are made last, so nothing is
///   ever written through one;
/// - `__MACOSX/` (AppleDouble metadata, not content) is skipped;
/// - at most `ZipInspector.maxEntries` entries (refused before anything is written);
/// - memory stays constant (64 KiB in, 256 KiB out, an autorelease pool per entry), and
///   `isCancelled` is asked between chunks.
///
/// What it wrote stays on failure; the caller unzips into a fresh folder and deletes it.
public enum ZipExtractor {
    public enum Failure: Error, Equatable, Sendable {
        case unreadable
        /// `ZipInspector` refused it.
        case unsafe(ZipInspector.Problem)
        case unsafeName
        case encrypted
        case unsupportedMethod(UInt16)
        /// More than `cap` declared in all.
        case tooLarge
        /// The data does not match what the directory declares: a stream that ends early or
        /// late, more or less output than declared, a stored size that differs, a short file.
        case damaged
        case crcMismatch
        case cancelled
        case writeFailed
    }

    public static let inputChunk = 64 << 10
    public static let outputChunk = 256 << 10

    /// Extracts `archive` into the existing folder `dest`. Returns how many entries were
    /// written (files, folders and links).
    @discardableResult
    public static func extract(_ archive: URL, into dest: URL, cap: UInt64, maxEntries: Int = ZipInspector.maxEntries,
                               isCancelled: () -> Bool = { false }) throws -> Int {
        guard let inspection = ZipInspector.inspect(archive, maxEntries: maxEntries) else { throw Failure.unreadable }
        if let problem = inspection.summary.problem { throw Failure.unsafe(problem) }
        guard inspection.summary.uncompressedBytes <= cap else { throw Failure.tooLarge }
        guard let handle = try? FileHandle(forReadingFrom: archive) else { throw Failure.unreadable }
        defer { try? handle.close() }

        // Plan every path first: a bad name refuses the archive before anything is written.
        var seen = Set<String>()
        var plan: [(entry: ZipInspector.Entry, parts: [String], kind: Kind)] = []
        for e in inspection.entries {
            if e.flags & 0x01 != 0 { throw Failure.encrypted }
            guard e.method == 0 || e.method == 8 else { throw Failure.unsupportedMethod(e.method) }
            let raw = String(decoding: e.name, as: UTF8.self)
            guard let parts = safeParts(raw) else { throw Failure.unsafeName }
            if parts.isEmpty { continue }   // "/" or "./": the folder itself
            // macOS's AppleDouble metadata (`__MACOSX/…/._name`): ditto turns it into
            // extended attributes; it is not content, so it is skipped.
            if parts[0] == "__MACOSX" { continue }
            guard seen.insert(parts.joined(separator: "/").lowercased()).inserted else { throw Failure.unsafeName }
            plan.append((e, parts, kind(of: e, name: raw)))
        }

        let fm = FileManager.default
        var links: [(URL, String)] = []
        var count = 0
        for (e, parts, kind) in plan {
            if isCancelled() { throw Failure.cancelled }
            // Foundation's per-file objects (URLs, handles, attributes) are freed per entry,
            // not when the whole archive is done.
            try autoreleasepool {
                let url = parts.reduce(dest) { $0.appendingPathComponent($1) }
                try makeParents(of: url, under: dest, fm)
                switch kind {
                case .folder:
                    guard e.uncompressed == 0 else { throw Failure.damaged }
                    if !fm.fileExists(atPath: url.path) {
                        do {
                            try fm.createDirectory(at: url, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: folderMode(e.mode)])
                        } catch { throw Failure.writeFailed }
                    }
                case .link:
                    // Stored and small (checked by ZipInspector); the target is the data.
                    var target = Data()
                    try copyData(e, from: handle, isCancelled: isCancelled) { target.append($0) }
                    links.append((url, String(decoding: target, as: UTF8.self)))
                case .file:
                    try writeFile(e, to: url, from: handle, isCancelled: isCancelled)
                }
            }
            count += 1
        }
        for (url, target) in links {
            guard !target.isEmpty, !target.hasPrefix("/"), !ZipInspector.isUnsafe(target) else {
                throw Failure.unsafe(.unsafeLink)
            }
            try autoreleasepool {
                do { try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target) } catch { throw Failure.writeFailed }
            }
        }
        return count
    }

    enum Kind { case file, folder, link }

    private static func kind(of e: ZipInspector.Entry, name: String) -> Kind {
        if let mode = e.mode {
            switch mode & 0o170000 {
            case 0o120000: return .link
            case 0o040000: return .folder
            default: break
            }
        }
        return name.hasSuffix("/") || name.hasSuffix("\\") ? .folder : .file
    }

    /// The path components to write `raw` at, or nil when it is unsafe (`..`, NUL).
    public static func safeParts(_ raw: String) -> [String]? {
        guard !raw.contains("\0") else { return nil }
        var parts: [String] = []
        for part in raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(String(part))
        }
        return parts
    }

    /// The archive's permission bits without group and other write (0o022: nothing
    /// unzipped is world-writable, and `setAttributes` ignores the umask) and without the
    /// set-ID and sticky bits; the owner can always read and write. 0644 when unset.
    static func fileMode(_ mode: UInt32?) -> Int {
        guard let mode, mode & 0o777 != 0 else { return 0o644 }
        return Int(mode & keptBits) | 0o600
    }

    /// As `fileMode`, the owner's rwx always; 0755 when unset.
    static func folderMode(_ mode: UInt32?) -> Int {
        guard let mode, mode & 0o777 != 0 else { return 0o755 }
        return Int(mode & keptBits) | 0o700
    }

    /// rwx for the owner, r-x for group and other.
    private static let keptBits: UInt32 = 0o777 & ~0o022

    /// Parent folders inside `dest` (made with 0755 when an archive lists files before
    /// their folder). Links are made last, so no parent here can be one.
    private static func makeParents(of url: URL, under dest: URL, _ fm: FileManager) throws {
        let parent = url.deletingLastPathComponent()
        guard parent.path != dest.path, !fm.fileExists(atPath: parent.path) else { return }
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch { throw Failure.writeFailed }
    }

    /// Writes the entry to `.<name>.partial-<uuid>` beside `url`, then renames it into place
    /// (never replacing). The partial is deleted on any failure.
    private static func writeFile(_ e: ZipInspector.Entry, to url: URL, from handle: FileHandle,
                                  isCancelled: () -> Bool) throws {
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent.prefix(100)).partial-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: partial) else { throw Failure.writeFailed }
        var ok = false
        defer {
            try? out.close()
            if !ok { try? FileManager.default.removeItem(at: partial) }
        }
        try copyData(e, from: handle, isCancelled: isCancelled) { chunk in
            do { try out.write(contentsOf: chunk) } catch { throw Failure.writeFailed }
        }
        try? out.close()
        let renamed = partial.withUnsafeFileSystemRepresentation { src in
            url.withUnsafeFileSystemRepresentation { dst -> Bool in
                guard let src, let dst else { return false }
                return renamex_np(src, dst, UInt32(RENAME_EXCL)) == 0
            }
        }
        guard renamed else { throw Failure.writeFailed }
        ok = true
        _ = try? FileManager.default.setAttributes([.posixPermissions: fileMode(e.mode)], ofItemAtPath: url.path)
    }

    /// Streams the entry's output to `sink`, checking the stream end, size and CRC.
    static func copyData(_ e: ZipInspector.Entry, from handle: FileHandle, isCancelled: () -> Bool,
                         sink: (Data) throws -> Void) throws {
        do { try handle.seek(toOffset: e.dataStart) } catch { throw Failure.damaged }
        var remaining = e.compressed
        var written: UInt64 = 0
        var crc = crc32(0, nil, 0)
        func emit(_ chunk: Data) throws {
            guard UInt64(chunk.count) <= e.uncompressed - written else { throw Failure.damaged }   // more than declared
            written += UInt64(chunk.count)
            crc = chunk.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            try sink(chunk)
        }
        /// The next chunk of the declared compressed bytes, and whether it is the last;
        /// nil when none are left.
        func nextInput() throws -> (data: Data, last: Bool)? {
            guard remaining > 0 else { return nil }
            let n = Int(min(remaining, UInt64(inputChunk)))
            guard let data = try? handle.read(upToCount: n), data.count == n else { throw Failure.damaged }   // truncated
            remaining -= UInt64(n)
            return (data, remaining == 0)
        }
        if e.method == 0 {
            guard e.compressed == e.uncompressed else { throw Failure.damaged }
            while let chunk = try nextInput() {
                if isCancelled() { throw Failure.cancelled }
                try emit(chunk.data)
            }
        } else {
            try inflate(nextInput: nextInput, emit: emit, isCancelled: isCancelled)
        }
        guard written == e.uncompressed else { throw Failure.damaged }
        guard UInt32(truncatingIfNeeded: crc) == e.crc else { throw Failure.crcMismatch }
    }

    /// Raw deflate with libz (windowBits -15): the stream must end exactly where the
    /// declared compressed bytes do, with no input left over and none missing.
    private static func inflate(nextInput: () throws -> (data: Data, last: Bool)?,
                                emit: (Data) throws -> Void, isCancelled: () -> Bool) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.damaged
        }
        defer { inflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: outputChunk)
        var ended = false
        while !ended {
            if isCancelled() { throw Failure.cancelled }
            // The stream needs more than the declared bytes: damaged.
            guard let chunk = try nextInput() else { throw Failure.damaged }
            var input = chunk.data
            let last = chunk.last
            try input.withUnsafeMutableBytes { (inBuf: UnsafeMutableRawBufferPointer) in
                stream.next_in = inBuf.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inBuf.count)
                repeat {
                    if isCancelled() { throw Failure.cancelled }
                    let produced: Int
                    let rc: Int32
                    (rc, produced) = out.withUnsafeMutableBufferPointer { outBuf in
                        stream.next_out = outBuf.baseAddress
                        stream.avail_out = uInt(outBuf.count)
                        let rc = zlib.inflate(&stream, Z_NO_FLUSH)
                        return (rc, outBuf.count - Int(stream.avail_out))
                    }
                    if produced > 0 { try emit(Data(out[0..<produced])) }
                    switch rc {
                    case Z_STREAM_END:
                        // It must end exactly at the declared size: nothing left here or after.
                        guard stream.avail_in == 0, last else { throw Failure.damaged }
                        ended = true
                    case Z_OK:
                        break
                    case Z_BUF_ERROR where stream.avail_in == 0:
                        break   // needs the next chunk
                    default:
                        throw Failure.damaged
                    }
                } while !ended && (stream.avail_in > 0 || stream.avail_out == 0)
            }
            if !ended && last { throw Failure.damaged }   // declared bytes ran out mid-stream
        }
    }
}
