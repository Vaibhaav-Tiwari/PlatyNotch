import Foundation

/// Little-endian bytes, appended field by field (no long `+` chains for the type checker).
struct Bytes {
    var data = Data()

    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    mutating func raw(_ d: Data) { data.append(d) }
    var count: Int { data.count }
}

/// Builds small stored (uncompressed) ZIP archives byte by byte, including broken and
/// hostile ones: headers that disagree, data descriptors, zip64 sizes, symbolic links.
struct ZipFixture {
    enum Descriptor { case none, matching, missing }

    struct Entry {
        var name: String
        var data: Data
        /// A different name in the local header (what ditto reads).
        var localName: String?
        /// Sizes the local header claims instead of the real ones.
        var localSize: UInt32?
        /// The uncompressed size the central directory claims instead of the real one.
        var centralSize: UInt64?
        /// Sizes in zip64 extra fields (both headers).
        var zip64 = false
        var descriptor = Descriptor.none
        /// A Unix mode (the external attributes' high 16 bits): e.g. 0o120755 for a link.
        var mode: UInt32?
        /// The made-by host byte (3 Unix, 0 DOS, 19 OS X); default 3 with a mode, else 0.
        var host: UInt16?

        init(_ name: String, _ data: Data = Data("x".utf8)) {
            self.name = name
            self.data = data
        }
    }

    /// `listed`: which entries the central directory lists (default all); the others are
    /// hidden local entries that only a reader of local headers (ditto) sees.
    static func build(_ entries: [Entry], listed: Set<Int>? = nil, prepend: Data = Data()) -> Data {
        var file = Bytes()
        file.raw(prepend)
        var central = Bytes()
        var listedCount = 0
        for (index, e) in entries.enumerated() {
            let offset = UInt32(file.count)
            let size = UInt64(e.data.count)
            let declared = e.centralSize ?? size
            let localName = Data((e.localName ?? e.name).utf8)
            let flags: UInt16 = e.descriptor == .none ? 0 : 8
            var localExtra = Bytes()
            var localC = e.localSize ?? UInt32(size)
            var localU = localC
            if e.zip64 {
                localC = 0xFFFF_FFFF
                localU = 0xFFFF_FFFF
                localExtra.u16(1); localExtra.u16(16); localExtra.u64(declared); localExtra.u64(size)
            } else if e.descriptor != .none {
                localC = 0
                localU = 0
            }
            file.u32(0x0403_4B50); file.u16(20); file.u16(flags); file.u16(0); file.u32(0); file.u32(0)
            file.u32(localC); file.u32(localU); file.u16(UInt16(localName.count)); file.u16(UInt16(localExtra.count))
            file.raw(localName); file.raw(localExtra.data); file.raw(e.data)
            if e.descriptor == .matching {
                file.u32(0x0807_4B50); file.u32(0); file.u32(UInt32(size)); file.u32(UInt32(declared))
            }
            let name = Data(e.name.utf8)
            var extra = Bytes()
            var c = UInt32(size)
            var u = UInt32(truncatingIfNeeded: declared)
            if e.zip64 {
                c = 0xFFFF_FFFF
                u = 0xFFFF_FFFF
                extra.u16(1); extra.u16(16); extra.u64(declared); extra.u64(size)
            }
            guard listed?.contains(index) ?? true else { continue }
            listedCount += 1
            let made: UInt16 = (e.host ?? (e.mode == nil ? 0 : 3)) << 8 | 20
            central.u32(0x0201_4B50); central.u16(made); central.u16(20); central.u16(flags); central.u16(0); central.u32(0)
            central.u32(0); central.u32(c); central.u32(u); central.u16(UInt16(name.count)); central.u16(UInt16(extra.count))
            central.u16(0); central.u16(0); central.u16(0); central.u32((e.mode ?? 0) << 16); central.u32(offset)
            central.raw(name); central.raw(extra.data)
        }
        let dirOffset = UInt32(file.count)
        file.raw(central.data)
        file.u32(0x0605_4B50); file.u16(0); file.u16(0); file.u16(UInt16(listedCount)); file.u16(UInt16(listedCount))
        file.u32(UInt32(central.count)); file.u32(dirOffset); file.u16(0)
        return file.data
    }
}
