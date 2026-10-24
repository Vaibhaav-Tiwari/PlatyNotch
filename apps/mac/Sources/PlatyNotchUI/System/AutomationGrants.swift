import Foundation
import PlatyNotchKit

/// Remembers, per scripted app, the `CodeIdentity` of the build whose Apple Events it
/// last accepted. A later refusal (-1743) can then tell "turned off" from "PlatyNotch was
/// rebuilt, so macOS no longer applies the grant and does not ask again" (feedback 6, 13).
@MainActor
struct AutomationGrants {
    static let keyPrefix = "automationGrant."

    let defaults: UserDefaults?
    let identity: () -> String

    func history(_ bundleID: String) -> GrantHistory {
        GrantHistory(savedStamp: defaults?.string(forKey: Self.keyPrefix + bundleID), current: identity())
    }

    func noteAccepted(_ bundleID: String) {
        defaults?.set(identity(), forKey: Self.keyPrefix + bundleID)
    }
}
