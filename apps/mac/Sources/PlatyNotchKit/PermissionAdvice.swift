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
    public static let bundleID = "dev.platynotch.app"
    /// Clears every Automation decision for PlatyNotch, so macOS asks again. Shown, never run.
    public static let resetAppleEvents = "tccutil reset AppleEvents \(bundleID)"

    public static func automationPath(_ app: String) -> String {
        "System Settings › Privacy & Security › Automation › PlatyNotch › \(app)"
    }

    /// An Apple Event to `app` was refused (-1743, or -1744 with no prompt shown).
    public static func automationDenied(app: String, history: GrantHistory) -> String {
        switch history {
        case .thisBuild:
            return "\(app) control is turned off for PlatyNotch. Turn it on in \(automationPath(app)), then try again."
        case .otherBuild:
            return "PlatyNotch was rebuilt or updated since you allowed \(app), so macOS no longer applies that and does not ask again. In Terminal run: \(resetAppleEvents) — then try again and click OK."
        case .never:
            return "PlatyNotch may not control \(app). Turn it on in \(automationPath(app)). If it is already on, or PlatyNotch is not listed, PlatyNotch was rebuilt and macOS does not ask again: in Terminal run \(resetAppleEvents), then try again."
        }
    }

    public static let accessibilityRebuilt =
        "PlatyNotch was rebuilt or updated: in System Settings › Privacy & Security › Accessibility remove PlatyNotch (−) and allow it again."

    /// How long after "Allow" a still-missing trust counts as stuck.
    public static let accessibilityStuckAfter: TimeInterval = 6

    /// True when the user allowed (or once had allowed) Accessibility but this build is
    /// still not trusted: show `accessibilityRebuilt`.
    public static func accessibilityStuck(trusted: Bool, allowClickedAt: Date?, now: Date, history: GrantHistory) -> Bool {
        if trusted { return false }
        if history == .otherBuild { return true }
        guard let allowClickedAt else { return false }
        return now.timeIntervalSince(allowClickedAt) >= accessibilityStuckAfter
    }
}
