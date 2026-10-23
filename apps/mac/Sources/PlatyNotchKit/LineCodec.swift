import Foundation

/// Splits a byte stream into newline-delimited messages, holding partial lines between feeds.
public struct LineCodec: Sendable {
    public static let maxLineBytes = 4 * 1024 * 1024

    private var buffer = Data()
    /// Set when a line exceeded `maxLineBytes`; the oversized line is discarded up to its newline.
    public private(set) var overflowed = false
    private var discarding = false

    public init() {}

    /// Feeds bytes and returns every complete, non-empty line (without the trailing newline).
    public mutating func feed(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var rest = data[...]
        while let nl = rest.firstIndex(of: 0x0A) {
            let chunk = rest[rest.startIndex..<nl]
            rest = rest[rest.index(after: nl)...]
            if discarding {
                discarding = false
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            if buffer.count + chunk.count > Self.maxLineBytes {
                overflowed = true
                buffer.removeAll(keepingCapacity: true)
                continue
            }
            buffer.append(contentsOf: chunk)
            if !buffer.isEmpty { lines.append(buffer) }
            buffer = Data()
        }
        if discarding { return lines }
        if buffer.count + rest.count > Self.maxLineBytes {
            overflowed = true
            discarding = true
            buffer = Data()
        } else {
            buffer.append(contentsOf: rest)
        }
        return lines
    }
}
