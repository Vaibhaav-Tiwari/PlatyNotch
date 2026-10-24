import Foundation

/// Decides which live activity owns the compact pill and which gets the side bubble.
public enum LiveArbiter {
    /// Drops expired activities, then the highest priority is `primary` and the next is
    /// `bubble`. Ties: the earlier one in `items` wins. An ambient activity is never the
    /// bubble next to a non-ambient one (ambient shows only when nothing else is live).
    public static func pick(_ items: [LiveActivity], now: Date) -> (primary: LiveActivity?, bubble: LiveActivity?) {
        let ranked = items.enumerated()
            .filter { !$0.element.isExpired(at: now) }
            .sorted { a, b in
                a.element.priority != b.element.priority ? a.element.priority > b.element.priority : a.offset < b.offset
            }
            .map(\.element)
        guard let primary = ranked.first else { return (nil, nil) }
        var bubble = ranked.dropFirst().first
        if let b = bubble, b.isAmbient, !primary.isAmbient { bubble = nil }
        return (primary, bubble)
    }

    /// Whether anything above ambient priority is live (Minimal mode keeps the pill up).
    public static func hasLive(_ items: [LiveActivity], now: Date) -> Bool {
        items.contains { !$0.isAmbient && !$0.isExpired(at: now) }
    }
}
