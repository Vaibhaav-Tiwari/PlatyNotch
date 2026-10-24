import Foundation

/// Whether a privacy grant was seen for this build. macOS ties Accessibility and
/// Automation grants to the code signature: an ad-hoc rebuild is a different app to it,
/// so a grant made to the previous build no longer applies (and Automation is not asked
/// again). The app saves its `CodeIdentity` stamp when it sees a grant work.
public enum GrantHistory: Equatable, Sendable {
    /// No grant seen.
    case never
    /// Seen for this very build.
    case thisBuild
    /// Seen for a build with another code identity (rebuilt or updated since).
    case otherBuild

    public init(savedStamp: String?, current: String) {
        guard let savedStamp, !savedStamp.isEmpty else { self = .never; return }
        self = savedStamp == current ? .thisBuild : .otherBuild
    }
}

/// What to tell the user when a permission does not work (user feedback 6, 7, 13).
/// PlatyNotch never changes privacy settings itself: these name the steps.
public enum PermissionAdvice {
    /// This app's bundle id (`dev.platynotch.app` when unbundled, e.g. `swift run`).
    public static var bundleID: String { Bundle.main.bundleIdentifier ?? "dev.platynotch.app" }
    /// Clears every Automation decision for PlatyNotch, so macOS asks again. Shown, never run.
    public static var resetAppleEvents: String { "tccutil reset AppleEvents \(bundleID)" }
    /// What the reset also takes away (the user re-allows each on next use).
    public static let resetScope =
        "This clears every Automation permission PlatyNotch has (terminal focus, Music, Spotify and browsers); each asks again the next time it is used."

    public static func automationPath(_ app: String) -> String {
        "System Settings › Privacy & Security › Automation › PlatyNotch › \(app)"
    }

    /// An Apple Event to `app` was refused (-1743, or -1744 with no prompt shown).
    public static func automationDenied(app: String, history: GrantHistory) -> String {
        switch history {
        case .thisBuild:
            return "\(app) control is turned off for PlatyNotch. Turn it on in \(automationPath(app)), then try again."
        case .otherBuild:
            return "PlatyNotch was rebuilt or updated since you allowed \(app), so macOS no longer applies that and does not ask again. In Terminal run: \(resetAppleEvents) — then try again and click OK. \(resetScope)"
        case .never:
            return "PlatyNotch may not control \(app). Turn it on in \(automationPath(app)). If it is already on, or PlatyNotch is not listed, PlatyNotch was rebuilt and macOS does not ask again: in Terminal run \(resetAppleEvents), then try again. \(resetScope)"
        }
    }

    /// Definite: trust was seen for another build of PlatyNotch.
    public static let accessibilityRebuilt =
        "PlatyNotch was rebuilt or updated: in System Settings › Privacy & Security › Accessibility remove PlatyNotch (−) and allow it again."
    /// Conditional: the user clicked Allow and came back, but nothing says the app was rebuilt
    /// (they may still be looking for the switch).
    public static let accessibilityMaybeStale =
        "If you already turned PlatyNotch on in Accessibility and this still shows, remove it (−) and allow it again."

    public enum AccessibilityAdvice: Equatable, Sendable {
        case none
        /// `accessibilityRebuilt`.
        case rebuilt
        /// `accessibilityMaybeStale`.
        case maybeStale

        public var text: String? {
            switch self {
            case .none: nil
            case .rebuilt: PermissionAdvice.accessibilityRebuilt
            case .maybeStale: PermissionAdvice.accessibilityMaybeStale
            }
        }
    }

    /// What to say while Accessibility is not trusted. A grant seen for another build is
    /// definite at once; otherwise only after the user clicked Allow and then came back
    /// (PlatyNotch active again, or System Settings left), never on a timer.
    public static func accessibility(trusted: Bool, returnedAfterAllow: Bool, history: GrantHistory) -> AccessibilityAdvice {
        if trusted { return .none }
        if history == .otherBuild { return .rebuilt }
        return returnedAfterAllow ? .maybeStale : .none
    }
}
