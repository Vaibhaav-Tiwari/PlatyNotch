import Foundation

/// Reads a ZIP archive's central directory (no extraction) to learn what unzipping would
/// write: how many entries and how many bytes they declare (R9's size cap). Zip64 sizes
/// are read. The declared sizes come from the archive and can lie, so the unzip also
/// watches what is really written.
public enum ZipInspector {
    public struct Summary: Equatable, Sendable {
        public var entries: Int
        public var uncompressedBytes: UInt64
        /// Some entry's name is absolute or climbs out with `..` (a "zip slip"): such an
        /// archive is never unzipped.
        public var hasUnsafeNames: Bool

        public init(entries: Int, uncompressedBytes: UInt64, hasUnsafeNames: Bool = false) {
            self.entries = entries
            self.uncompressedBytes = uncompressedBytes
            self.hasUnsafeNames = hasUnsafeNames
        }
    }

    /// A central directory larger than this is not read (nil).
    public static let maxDirectoryBytes = 64 << 20

    /// Nil when `url` is not a readable ZIP archive.
    public static func summary(of url: URL) -> Summary? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }
        // The end record is in the last 22 + 65 535 (comment) bytes.
        let tailLength = min(size, 22 + 65_535)
        guard let tail = read(handle, at: size - tailLength, count: Int(tailLength)),
              let eocd = lastIndex(of: 0x0605_4B50, in: tail) else { return nil }
        var entries = UInt64(tail.u16(eocd + 10))
        var dirSize = UInt64(tail.u32(eocd + 12))
        var dirOffset = UInt64(tail.u32(eocd + 16))
        if entries == 0xFFFF || dirSize == 0xFFFF_FFFF || dirOffset == 0xFFFF_FFFF {
            // Zip64: a locator just before the end record points at the zip64 end record.
            let eocdAt = size - tailLength + UInt64(eocd)
            guard eocdAt >= 20, let locator = read(handle, at: eocdAt - 20, count: 20),
                  locator.u32(0) == 0x0706_4B50,
                  let record = read(handle, at: locator.u64(8), count: 56), record.u32(0) == 0x0606_4B50
            else { return nil }
            entries = record.u64(32)
            dirSize = record.u64(40)
            dirOffset = record.u64(48)
        }
        guard dirSize <= UInt64(maxDirectoryBytes), dirOffset + dirSize <= size,
              let dir = read(handle, at: dirOffset, count: Int(dirSize)) else { return nil }
        return parseDirectory(dir, entries: entries)
    }

    private static func parseDirectory(_ dir: Data, entries: UInt64) -> Summary? {
        var at = 0
        var total: UInt64 = 0
        var count = 0
        var unsafe = false
        while count < entries {
            guard at + 46 <= dir.count, dir.u32(at) == 0x0201_4B50 else { return nil }
            var size = UInt64(dir.u32(at + 24))
            let nameLength = Int(dir.u16(at + 28)), extraLength = Int(dir.u16(at + 30))
            let commentLength = Int(dir.u16(at + 32))
            let extraStart = at + 46 + nameLength
            guard extraStart + extraLength + commentLength <= dir.count else { return nil }
            let nameStart = dir.startIndex + at + 46
            if isUnsafe(String(decoding: dir[nameStart..<(nameStart + nameLength)], as: UTF8.self)) { unsafe = true }
            if size == 0xFFFF_FFFF {
                guard let big = zip64Size(dir, from: extraStart, length: extraLength) else { return nil }
                size = big
            }
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { return nil }
            total = sum
            count += 1
            at = extraStart + extraLength + commentLength
        }
        return Summary(entries: count, uncompressedBytes: total, hasUnsafeNames: unsafe)
    }

    /// An entry name that would land outside the folder it is unzipped into.
    public static func isUnsafe(_ name: String) -> Bool {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        return name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("\0") || parts.contains("..")
    }

    /// The uncompressed size in the zip64 extra field (id 1; it comes first in it).
    private static func zip64Size(_ dir: Data, from start: Int, length: Int) -> UInt64? {
        var at = start
        while at + 4 <= start + length {
            let id = dir.u16(at), fieldLength = Int(dir.u16(at + 2))
            if id == 1, fieldLength >= 8, at + 4 + 8 <= dir.count { return dir.u64(at + 4) }
            at += 4 + fieldLength
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
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
