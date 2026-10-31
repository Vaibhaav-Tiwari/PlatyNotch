import AppKit

/// The localized name of the app that hosts a session ("Claude", "Ghostty"), for the Open
/// button. nil when the app is not installed. Cached; the cache is cleared whenever an app
/// launches or quits (a running app's name can differ from its bundle's file name).
@MainActor
enum HostAppName {
    private static var cache: [String: String?] = [:]
    private static var observers: [NSObjectProtocol] = []

    /// Tests replace this.
    static var lookup: (String) -> String? = { cached($0) }

    private static func cached(_ id: String) -> String? {
        observeOnce()
        if let hit = cache[id] { return hit }
        let name = resolve(id)
        cache[id] = .some(name)
        return name
    }

    private static func resolve(_ id: String) -> String? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return name.isEmpty ? nil : name
    }

    private static func observeOnce() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { cache.removeAll() }
            })
        }
    }
}
