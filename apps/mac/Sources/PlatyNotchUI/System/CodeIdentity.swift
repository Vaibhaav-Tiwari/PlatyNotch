import Foundation
import Security

/// This build's code identity, the stamp saved with a Downloads-folder grant. macOS ties
/// privacy grants to the code signature, so a new identity (an update, a reinstall, an
/// ad-hoc rebuild) may have lost the grant; the downloads sub-feature then stays off
/// until its button is pressed again, and nothing is stat'ed at launch.
///
/// - `cdhash:<hex>`: `kSecCodeInfoUnique` from `SecCodeCopySigningInformation` of this
///   process's static code. Every signed build has one, including ad-hoc `.app` builds
///   and SwiftPM's linker-signed debug executables under `swift run` (so each rebuild
///   there asks again).
/// - `dr:<requirement>`: the designated requirement, if no cdhash is available.
/// - `unsigned-dev`: neither (an unsigned executable); stable across rebuilds.
enum CodeIdentity {
    static let unsigned = "unsigned-dev"

    /// Computed once per launch.
    static let current: String = compute()

    private static func compute() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return unsigned }
        var info: CFDictionary?
        if SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any], let unique = dict[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty {
            return "cdhash:" + unique.map { String(format: "%02x", $0) }.joined()
        }
        var requirement: SecRequirement?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
            var text: CFString?
            if SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text {
                return "dr:" + (text as String)
            }
        }
        return unsigned
    }
}
