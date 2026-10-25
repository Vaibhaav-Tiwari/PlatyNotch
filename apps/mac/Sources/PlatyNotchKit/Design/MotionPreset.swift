import Foundation

/// A spring: `response` seconds and `damping` (1.0 never overshoots).
public struct SpringSpec: Equatable, Sendable {
    public var response: Double
    public var damping: Double

    public init(response: Double, damping: Double) {
        self.response = response
        self.damping = damping
    }
}

/// Whether a mode change opens the panel (grows it) or closes it.
public enum MotionDirection: Sendable {
    case open, close

    /// Open when leaving the pill (`.hidden` / `.compact`) for anything larger, or a peek
    /// growing into the full panel; every other change closes.
    public static func between(_ old: PanelMode, _ new: PanelMode) -> MotionDirection {
        switch (old, new) {
        case (.hidden, .hidden), (.hidden, .compact), (.compact, .hidden), (.compact, .compact):
            return .close
        case (.hidden, _), (.compact, _):
            return .open
        case (.peek, .expanded):
            return .open
        default:
            return .close
        }
    }
}

/// Settings › Appearance › Motion (spec 9): the open and close springs.
/// No preset blurs; Reduced is a cross-fade only.
public enum MotionPreset: String, Codable, CaseIterable, Sendable {
    case calm, lively, reduced

    /// The spring for a mode change, or nil for Reduced (cross-fade `reducedFade`).
    public func spring(_ d: MotionDirection) -> SpringSpec? {
        switch (self, d) {
        case (.reduced, _): nil
        case (_, .close): SpringSpec(response: 0.35, damping: 1.0)
        case (.calm, .open): SpringSpec(response: 0.38, damping: 0.86)
        case (.lively, .open): SpringSpec(response: 0.42, damping: 0.78)
        }
    }

    /// Content cross-fades never take longer than this.
    public static let crossFade: Double = 0.2
    /// Reduced's (and Reduce Motion's) mode-change fade.
    public static let reducedFade: Double = 0.15
}

extension AppearanceSettings {
    /// The preset in effect: the system's Reduce Motion always wins.
    public func effectiveMotion(reduceMotion: Bool) -> MotionPreset {
        reduceMotion ? .reduced : motion
    }
}
