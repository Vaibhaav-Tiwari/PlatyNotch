import AppKit
import Observation
import PlatyNotchKit
@preconcurrency import Sparkle

/// Sparkle updates. On only when the bundle's Info.plist has a `SUPublicEDKey`
/// (`UpdaterConfig`); otherwise, and under `swift run`, no updater is created and
/// "updates" means the GitHub Releases page.
@MainActor @Observable
final class AppUpdater {
    let isEnabled: Bool
    @ObservationIgnored private let controller: SPUStandardUpdaterController?

    /// Sparkle's "Automatically check for updates" (stored in the app's defaults by Sparkle).
    var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    /// `start: false` builds the updater without starting it (smoke runs: no feed fetch,
    /// no permission prompt).
    init(start: Bool, enabled: Bool = UpdaterConfig.current) {
        isEnabled = enabled
        if enabled {
            let c = SPUStandardUpdaterController(startingUpdater: start, updaterDelegate: nil, userDriverDelegate: nil)
            controller = c
            automaticallyChecks = c.updater.automaticallyChecksForUpdates
        } else {
            controller = nil
            automaticallyChecks = false
        }
    }

    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// "Check for Updates…", or the Releases page when updates are off.
    func checkForUpdates() {
        if let controller {
            NSApp.activate()
            controller.checkForUpdates(nil)
        } else {
            openReleases()
        }
    }

    func openReleases() { NSWorkspace.shared.open(UpdaterConfig.releasesURL) }

    /// "0.1.0 (42)", or "development build" outside a bundle.
    /// "Version 1.2 (34)", or "Development build" outside an installed app.
    static var versionLine: String {
        Bundle.main.bundleURL.pathExtension == "app" ? "Version \(versionDescription)" : "Development build"
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app",
              let short = info["CFBundleShortVersionString"] as? String else { return "development build" }
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty { return "\(short) (\(build))" }
        return short
    }
}
