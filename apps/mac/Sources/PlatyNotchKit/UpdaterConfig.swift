import Foundation

/// Whether Sparkle updates are on for this build. They need a bundle whose Info.plist has
/// a non-empty `SUPublicEDKey` (set from `SPARKLE_ED_PUBLIC_KEY` by scripts/build-app.sh)
/// and an https `SUFeedURL`; otherwise updates are manual, from GitHub Releases.
public enum UpdaterConfig {
    public static let releasesURL = URL(string: "https://github.com/Vaibhaav-Tiwari/PlatyNotch/releases")!

    public static func isEnabled(info: [String: Any]?, bundleURL: URL) -> Bool {
        guard bundleURL.pathExtension == "app", let info else { return false }
        guard let key = info["SUPublicEDKey"] as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
              url.scheme == "https", url.host != nil else { return false }
        return true
    }

    /// For the running app.
    public static var current: Bool {
        isEnabled(info: Bundle.main.infoDictionary, bundleURL: Bundle.main.bundleURL)
    }
}
