import Foundation

/// Recognises a shake of the pointer while dragging (R3, groundwork for baskets): the
/// horizontal direction reverses at least `threshold` times within `window` seconds, and
/// every leg between two turns travels at least `minTravel` points. Pure: feed it pointer
/// samples (the drag monitor's 0.05 s poll gives about 10 in the window).
///
/// `threshold = 8 - sensitivity`, sensitivity 1…5 (clamped), so 7 reversals at the
/// least sensitive setting and 3 at the most.
public struct ShakeDetector: Equatable, Sendable {
    public static let minTravel: Double = 30
    public static let window: TimeInterval = 0.5
    public static let sensitivityRange: ClosedRange<Int> = 1...5
    public static let defaultSensitivity = 3

    /// Reversals needed within `window`: `8 - sensitivity`, so 3...7.
    public static func threshold(sensitivity: Int) -> Int {
        8 - min(max(sensitivity, sensitivityRange.lowerBound), sensitivityRange.upperBound)
    }

    public let threshold: Int
    /// +1 right, -1 left, 0 before the first leg of `minTravel`.
    private var direction: Double = 0
    /// Where the current leg started (the last turn, or the first sample).
    private var anchor: Double?
    /// The furthest point of the current leg.
    private var extreme: Double = 0
    /// When each recent reversal happened (inside `window`).
    private var reversals: [TimeInterval] = []

    public init(sensitivity: Int = ShakeDetector.defaultSensitivity) {
        threshold = Self.threshold(sensitivity: sensitivity)
    }

    /// One pointer sample (`x` in points, `time` in seconds, increasing). True when this
    /// sample completes a shake; the detector then starts over, so one shake reports once.
    public mutating func feed(x: Double, time: TimeInterval) -> Bool {
        guard let start = anchor else {
            anchor = x
            extreme = x
            return false
        }
        if direction == 0 {
            guard abs(x - start) >= Self.minTravel else { return false }
            direction = x > start ? 1 : -1
            extreme = x
            return false
        }
        if (x - extreme) * direction > 0 {
            extreme = x   // further the same way
            return false
        }
        guard (extreme - x) * direction >= Self.minTravel else { return false }
        // Turned back by at least a leg's length: a reversal at the extreme.
        anchor = extreme
        direction = -direction
        extreme = x
        reversals.append(time)
        reversals.removeAll { time - $0 > Self.window }
        guard reversals.count >= threshold else { return false }
        reset()
        return true
    }

    /// Forgets the movement so far (a drag ended, or the gate closed).
    public mutating func reset() {
        direction = 0
        anchor = nil
        extreme = 0
        reversals = []
    }
}

/// When the shake detector may be fed (R3): only while a drag is in progress, and only
/// for a drag whose pasteboard *types* (never its contents) the shelf would take
/// (`ShelfDropPolicy.accepts`: nothing concealed or transient) and that carries a file
/// or a URL. A text selection being dragged never feeds it.
///
/// This reads the drag pasteboard's type list during a drag, a deliberate extension of
/// the shelf's "pasteboard read on drop only" rule: types only, never the data.
public enum ShakeGate {
    /// File, file-promise and URL type identifiers (`NSPasteboard.PasteboardType.fileURL`
    /// and `.URL`, `NSFilePromiseReceiver.readableDraggedTypes`, the legacy filenames type).
    public static let fileOrURLTypes: Set<String> = [
        "public.file-url",
        "public.url",
        "NSFilenamesPboardType",
        "com.apple.NSFilePromiseItemMetaData",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
    ]

    public static func shouldFeed(isDragging: Bool, dragTypes: [String]) -> Bool {
        guard isDragging, ShelfDropPolicy.accepts(types: dragTypes) else { return false }
        return dragTypes.contains { fileOrURLTypes.contains($0) }
    }
}
