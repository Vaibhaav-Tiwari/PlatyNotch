import Foundation
import Security

/// This build's code identity, the stamp saved with a privacy grant (the System widget's
/// Downloads folder, the music visualiser's System Audio Recording). macOS ties privacy
/// grants to the code signature's designated requirement, so a different one may have
/// lost the grant; the feature then stays off until its button or toggle is used again,
/// and nothing that could prompt runs at launch (`grantHolds`).
///
/// In order:
/// - `dr:<requirement>`: the designated requirement, which is what TCC records. A
///   Developer ID build's is anchor + team + identifier, stable across updates (as is the
///   grant). An ad-hoc build's is its cdhash, so each rebuild asks again (also SwiftPM's
///   linker-signed debug executables under `swift run`).
/// - `cdhash:<hex>`: `kSecCodeInfoUnique`, when no requirement can be read.
/// - `unsigned-dev`: neither (an unsigned executable); stable across rebuilds.
///
/// Stamps saved before this order (`cdhash:` from a signed build) differ once: "Turn on again".
enum CodeIdentity {
    static let unsigned = "unsigned-dev"

    /// Computed once per launch.
    static let current: String = stamp(requirement: designatedRequirement(), cdhash: cdhash())

    /// A grant saved with `saved` still belongs to this build (`current`): only then may a
    /// feature that needs it run without the user turning it on again.
    static func grantHolds(_ saved: String?, current: String) -> Bool {
        guard let saved, !saved.isEmpty else { return false }
        return saved == current
    }

    /// The stamp from what the signature gives; pure.
    static func stamp(requirement: String?, cdhash: Data?) -> String {
        if let requirement, !requirement.isEmpty { return "dr:" + requirement }
        if let cdhash, !cdhash.isEmpty { return "cdhash:" + cdhash.map { String(format: "%02x", $0) }.joined() }
        return unsigned
    }

    private static func selfStaticCode() -> SecStaticCode? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    private static func designatedRequirement() -> String? {
        guard let staticCode = selfStaticCode() else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess,
              let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    private static func cdhash() -> Data? {
        guard let staticCode = selfStaticCode() else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoUnique as String] as? Data
    }
}
