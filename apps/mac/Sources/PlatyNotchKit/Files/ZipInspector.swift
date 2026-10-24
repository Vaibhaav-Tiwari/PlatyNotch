import Foundation

/// Reads a ZIP archive's directory and every entry's local header (no extraction) to learn
/// what unzipping would write (R9's size cap), and whether it is safe to unzip at all.
///
/// `ditto` streams the local headers in file order, not the central directory, so an
/// archive whose two copies disagree, or that hides entries the directory does not list,
/// could declare 9 bytes and write gigabytes: such an archive is refused (`problem`). The
/// local entries must tile the file from offset 0 up to the directory exactly, one per
/// central record and in the same order. Zip64 sizes are read. Even honest declared sizes do not bound what
/// a compressed stream inflates to, so the unzip also watches what is really written.
public enum ZipInspector {
    /// Why an archive is never unzipped.
    public enum Problem: String, Error, Equatable, Sendable {
        /// An entry's name is absolute or climbs out with `..` (a "zip slip").
        case unsafeName
        /// An entry's local header disagrees with its central record (name, method or sizes),
        /// or lies outside the file.
        case mismatchedHeaders
        /// A data descriptor whose sizes cannot be read or do not match.
        case unknownSizes
        /// A symbolic link whose target is absolute, climbs out with `..`, or cannot be read.
        case unsafeLink
        /// Bytes before the directory that no listed entry accounts for: a hidden entry, a
        /// gap, entries out of order, or anything prepended.
        case unlistedData
    }

    public struct Summary: Equatable, Sendable {
        public var entries: Int
        public var uncompressedBytes: UInt64
        public var problem: Problem?

        public init(entries: Int, uncompressedBytes: UInt64, problem: Problem? = nil) {
            self.entries = entries
            self.uncompressedBytes = uncompressedBytes
            self.problem = problem
        }
    }

    /// A central directory larger than this is not read (nil).
    public static let maxDirectoryBytes = 64 << 20
    /// A symbolic link target longer than this is refused.
    public static let maxLinkTarget = 4096

    /// One central directory record (what `ZipExtractor` extracts from).
    struct Entry {
        var name: Data
        var flags: UInt16
        var method: UInt16
        var compressed: UInt64
        var uncompressed: UInt64
        var localOffset: UInt64
        /// The Unix mode (the high 16 bits of the external attributes), when set.
        var mode: UInt32?
        var crc: UInt32 = 0
        /// Where the entry's data starts (after its local header); set by `inspect`.
        var dataStart: UInt64 = 0
    }

    /// The checked directory: its summary and entries, in directory order.
    struct Inspection {
        var summary: Summary
        var entries: [Entry]
    }

    /// Nil when `url` is not a readable ZIP archive.
    public static func summary(of url: URL) -> Summary? {
        inspect(url)?.summary
    }

    static func inspect(_ url: URL) -> Inspection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        // The end record is in the last 22 + 65 535 (comment) bytes.
        let tailLength = min(size, 22 + 65_535)
        guard let tail = read(handle, at: size - tailLength, count: Int(tailLength)),
              let eocd = lastIndex(of: 0x0605_4B50, in: tail) else { return nil }
        var count = UInt64(tail.u16(eocd + 10))
        var dirSize = UInt64(tail.u32(eocd + 12))
        var dirOffset = UInt64(tail.u32(eocd + 16))
        if count == 0xFFFF || dirSize == 0xFFFF_FFFF || dirOffset == 0xFFFF_FFFF {
            // Zip64: a locator just before the end record points at the zip64 end record.
            let eocdAt = size - tailLength + UInt64(eocd)
            guard eocdAt >= 20, let locator = read(handle, at: eocdAt - 20, count: 20),
                  locator.u32(0) == 0x0706_4B50, locator.u64(8) < size,
                  let record = read(handle, at: locator.u64(8), count: 56), record.u32(0) == 0x0606_4B50
            else { return nil }
            count = record.u64(32)
            dirSize = record.u64(40)
            dirOffset = record.u64(48)
        }
        // Written so nothing can overflow (zip64 values are attacker-chosen).
        guard dirSize <= UInt64(maxDirectoryBytes), dirOffset <= size, dirSize <= size - dirOffset,
              let dir = read(handle, at: dirOffset, count: Int(dirSize)),
              let entries = parseDirectory(dir, count: count) else { return nil }
        var total: UInt64 = 0
        var problem: Problem?
        var checked: [Entry] = []
        // Where the next local entry may start: one place, or two when a data descriptor
        // could be the 4- or 8-byte form (the next offset decides).
        var expected: Set<UInt64> = [0]
        for var e in entries {
            let (sum, overflow) = total.addingReportingOverflow(e.uncompressed)
            guard !overflow else { return nil }
            total = sum
            guard problem == nil else { continue }
            switch check(e, handle: handle, fileSize: size) {
            case .failure(let p): problem = p
            case .success(let r):
                if !expected.contains(e.localOffset) { problem = .unlistedData }
                expected = r.ends
                e.dataStart = r.dataStart
                checked.append(e)
            }
        }
        if problem == nil, !expected.contains(dirOffset) { problem = .unlistedData }
        return Inspection(summary: Summary(entries: entries.count, uncompressedBytes: total, problem: problem),
                          entries: checked)
    }

    private static func parseDirectory(_ dir: Data, count: UInt64) -> [Entry]? {
        var at = 0
        var out: [Entry] = []
        while UInt64(out.count) < count {
            guard at <= dir.count - 46, dir.u32(at) == 0x0201_4B50 else { return nil }
            var e = Entry(name: Data(), flags: dir.u16(at + 8), method: dir.u16(at + 10),
                          compressed: UInt64(dir.u32(at + 20)), uncompressed: UInt64(dir.u32(at + 24)),
                          localOffset: UInt64(dir.u32(at + 42)), mode: nil, crc: dir.u32(at + 16))
            let nameLength = Int(dir.u16(at + 28)), extraLength = Int(dir.u16(at + 30))
            let commentLength = Int(dir.u16(at + 32))
            let nameStart = at + 46, extraStart = nameStart + nameLength
            guard extraStart + extraLength + commentLength <= dir.count else { return nil }
            e.name = Data(dir[(dir.startIndex + nameStart)..<(dir.startIndex + extraStart)])
            // The Unix mode is the high 16 bits of the external attributes, whatever the
            // made-by byte says (ditto makes links for made-by 0 and 19 too).
            let mode = dir.u32(at + 38) >> 16
            if mode != 0 { e.mode = mode }
            guard readZip64(dir, from: extraStart, length: extraLength, into: &e, local: false) else { return nil }
            out.append(e)
            at = extraStart + extraLength + commentLength
        }
        return out
    }

    /// Replaces the 0xFFFFFFFF fields of `e` from the zip64 extra field (id 1), in the
    /// order the format gives them. False when one is needed and missing.
    private static func readZip64(_ data: Data, from start: Int, length: Int, into e: inout Entry, local: Bool) -> Bool {
        let wantU = e.uncompressed == 0xFFFF_FFFF, wantC = e.compressed == 0xFFFF_FFFF
        let wantO = !local && e.localOffset == 0xFFFF_FFFF
        guard wantU || wantC || wantO else { return true }
        var at = start
        while at + 4 <= start + length {
            let id = data.u16(at), fieldLength = Int(data.u16(at + 2))
            let body = at + 4
            guard body + fieldLength <= start + length else { return false }
            if id == 1 {
                var p = body
                // A local header's zip64 field holds both sizes whenever it is present.
                for (want, keyPath) in [(wantU || local, \Entry.uncompressed), (wantC || local, \Entry.compressed),
                                        (wantO, \Entry.localOffset)] where want {
                    guard p + 8 <= body + fieldLength else { return false }
                    e[keyPath: keyPath] = data.u64(p)
                    p += 8
                }
                return true
            }
            at = body + fieldLength
        }
        return false
    }

    /// The entry's local header (what ditto reads) against its central record: where the
    /// entry (header, data and any descriptor) ends, or why it is refused.
    private static func check(_ e: Entry, handle: FileHandle,
                              fileSize: UInt64) -> Result<(dataStart: UInt64, ends: Set<UInt64>), Problem> {
        if isUnsafe(String(decoding: e.name, as: UTF8.self)) { return .failure(.unsafeName) }
        guard e.localOffset <= fileSize, fileSize - e.localOffset >= 30,
              let header = read(handle, at: e.localOffset, count: 30), header.u32(0) == 0x0403_4B50 else {
            return .failure(.mismatchedHeaders)
        }
        let nameLength = UInt64(header.u16(26)), extraLength = UInt64(header.u16(28))
        let variable = nameLength + extraLength
        guard fileSize - e.localOffset - 30 >= variable,
              let rest = read(handle, at: e.localOffset + 30, count: Int(variable)) else { return .failure(.mismatchedHeaders) }
        var local = Entry(name: Data(rest.prefix(Int(nameLength))), flags: header.u16(6), method: header.u16(8),
                          compressed: UInt64(header.u32(18)), uncompressed: UInt64(header.u32(22)),
                          localOffset: e.localOffset, mode: nil)
        guard local.name == e.name, local.method == e.method,
              readZip64(rest, from: Int(nameLength), length: Int(extraLength), into: &local, local: true) else {
            return .failure(.mismatchedHeaders)
        }
        let dataStart = e.localOffset + 30 + variable
        guard dataStart <= fileSize, e.compressed <= fileSize - dataStart else { return .failure(.mismatchedHeaders) }
        let end = dataStart + e.compressed
        var ends: Set<UInt64> = [end]
        if local.flags & 0x08 != 0 {
            // Sizes follow the data, in a data descriptor: they must be there and agree.
            let lengths = descriptorLengths(e, at: end, handle: handle, fileSize: fileSize)
            guard !lengths.isEmpty else { return .failure(.unknownSizes) }
            ends = Set(lengths.map { end + $0 })
        } else if local.compressed != e.compressed || local.uncompressed != e.uncompressed {
            return .failure(.mismatchedHeaders)
        }
        if let mode = e.mode, mode & 0o170000 == 0o120000 {
            // A symbolic link: its target is the entry's (stored) data.
            guard e.method == 0, e.compressed <= UInt64(maxLinkTarget),
                  let target = read(handle, at: dataStart, count: Int(e.compressed)) else { return .failure(.unsafeLink) }
            let path = String(decoding: target, as: UTF8.self)
            if path.isEmpty || path.hasPrefix("/") || isUnsafe(path) { return .failure(.unsafeLink) }
        }
        return .success((dataStart, ends))
    }

    /// [signature] crc, compressed, uncompressed: 4-byte sizes, or 8-byte for zip64. The
    /// lengths of the forms that are there and agree with the directory (both can, for
    /// small sizes: a zip64 descriptor of an empty file reads as a 4-byte one too). The
    /// next entry's offset picks the one that is real.
    private static func descriptorLengths(_ e: Entry, at offset: UInt64, handle: FileHandle, fileSize: UInt64) -> [UInt64] {
        guard offset <= fileSize else { return [] }
        let available = min(fileSize - offset, 24)
        guard let d = read(handle, at: offset, count: Int(available)) else { return [] }
        var out: [UInt64] = []
        for start in d.count >= 4 && d.u32(0) == 0x0807_4B50 ? [4, 0] : [0] {
            if d.count >= start + 12, d.u32(start) == e.crc, UInt64(d.u32(start + 4)) == e.compressed,
               UInt64(d.u32(start + 8)) == e.uncompressed {
                out.append(UInt64(start + 12))
            }
            if d.count >= start + 20, d.u32(start) == e.crc, d.u64(start + 4) == e.compressed,
               d.u64(start + 12) == e.uncompressed {
                out.append(UInt64(start + 20))
            }
        }
        return out
    }

    /// An entry name (or link target) that would land outside the folder it is unzipped into.
    public static func isUnsafe(_ name: String) -> Bool {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        return name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("\0") || parts.contains("..")
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        if count == 0 { return Data() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return data
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        var i = data.count - 22
        while i >= 0 {
            if data.u32(i) == signature { return i }
            i -= 1
        }
        return nil
    }
}

private extension Data {
    func u16(_ i: Int) -> UInt16 {
        let s = startIndex + i
        return UInt16(self[s]) | UInt16(self[s + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
    }

    func u64(_ i: Int) -> UInt64 {
        UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
    }
}
