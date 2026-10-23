import Foundation

/// Turns raw "cursor inside the hit rect" samples into debounced hover enter/exit:
/// entering needs `enterDelay` of dwell, leaving needs `exitDelay` of absence.
public struct HoverDebouncer: Sendable {
    public static let defaultEnterDelay: TimeInterval = 0.12
    public static let defaultExitDelay: TimeInterval = 0.35

    public let enterDelay: TimeInterval
    public let exitDelay: TimeInterval
    public private(set) var isHovering = false
    private var pendingSince: TimeInterval?

    public init(enterDelay: TimeInterval = defaultEnterDelay, exitDelay: TimeInterval = defaultExitDelay) {
        self.enterDelay = enterDelay
        self.exitDelay = exitDelay
    }

    /// When the pending change would commit if the cursor stays where it is; nil when nothing is pending.
    public var deadline: TimeInterval? {
        pendingSince.map { $0 + (isHovering ? exitDelay : enterDelay) }
    }

    /// Feeds one sample. Returns the new hover state when it flips, else nil.
    public mutating func update(inside: Bool, at now: TimeInterval) -> Bool? {
        guard inside != isHovering else { pendingSince = nil; return nil }
        let since = pendingSince ?? now
        pendingSince = since
        guard let deadline, now >= deadline else { return nil }
        isHovering = inside
        pendingSince = nil
        return inside
    }

    public mutating func reset(hovering: Bool) {
        isHovering = hovering
        pendingSince = nil
    }
}
