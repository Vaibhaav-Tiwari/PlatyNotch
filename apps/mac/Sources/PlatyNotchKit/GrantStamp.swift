import Foundation

/// The "Turn on again after a rebuild" pattern for one privacy-gated feature (camera
/// mirror, and later others), generalising what the Downloads folder, the visualiser and
/// Accessibility already do by hand: when the feature's grant is seen to work, the
/// build's code identity (`CodeIdentity.current` in the UI) is saved under `key`. macOS
/// ties privacy grants to the code signature, so at launch a feature that was on resumes
/// only when the saved stamp is this build's; otherwise it turns itself off and asks the
/// user to turn it on again (from its own button), and nothing that could prompt runs.
public struct GrantStamp {
    /// What `launchCheck` decides for a feature saved as on or off.
    public enum Launch: Equatable, Sendable {
        /// It was off: nothing to do.
        case off
        /// On, granted to this build: start it.
        case resume
        /// On, but the grant was made to another build (or never stamped): it is now off
        /// (the stamp cleared) and Settings shows "Turn On Again".
        case turnOnAgain
    }

    /// UserDefaults key of the stamp (a setting, never user data), e.g. "camera.grant".
    public let key: String
    private let defaults: UserDefaults
    private let identity: () -> String

    public init(key: String, defaults: UserDefaults = .standard, identity: @escaping () -> String) {
        self.key = key
        self.defaults = defaults
        self.identity = identity
    }

    /// A grant saved with `saved` belongs to the build `current`: only then may a feature
    /// that needs it run without the user turning it on again.
    public static func holds(_ saved: String?, current: String) -> Bool {
        guard let saved, !saved.isEmpty else { return false }
        return saved == current
    }

    public var saved: String? { defaults.string(forKey: key) }

    /// The saved grant is this build's.
    public var holds: Bool { Self.holds(saved, current: identity()) }

    /// Never, this build, or another build (for permission advice).
    public var history: GrantHistory { GrantHistory(savedStamp: saved, current: identity()) }

    /// The grant was seen to work: stamp it with this build (writes only on a change).
    public func note() {
        let now = identity()
        if saved != now { defaults.set(now, forKey: key) }
    }

    public func clear() {
        defaults.removeObject(forKey: key)
    }

    /// At launch, for a feature saved as `wasOn`: resume only when the grant holds, else
    /// clear the stamp and report `turnOnAgain` (the caller saves the feature as off).
    public func launchCheck(wasOn: Bool) -> Launch {
        guard wasOn else { return .off }
        if holds { return .resume }
        clear()
        return .turnOnAgain
    }
}
