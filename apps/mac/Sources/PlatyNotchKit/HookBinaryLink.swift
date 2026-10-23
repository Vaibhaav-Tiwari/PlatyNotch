import Darwin
import Foundation

/// Keeps `<home>/bin/notch` (the path agent configs call) pointed at the `notch` inside
/// the running app bundle, so hooks follow the app when it is moved or updated.
/// The standalone CLI creates the link when nothing is there (`ensureHookBinary` in
/// core/cli); the app re-points it on launch.
public enum HookBinaryLink {
    public enum Outcome: Equatable, Sendable {
        case created
        case repointed(from: String)
        case unchanged
        /// A regular file (or directory) is there: the user put it there, so it is left alone.
        case keptRegularFile
        /// Not running from a usable app bundle (`swift run`, translocated, read-only volume).
        case skipped(String)
        case failed(String)
    }

    /// `Contents/MacOS/notch` when `bundleURL` is an `.app` that contains it.
    public static func bundledCore(bundleURL: URL, fileManager fm: FileManager = .default) -> URL? {
        guard bundleURL.pathExtension == "app" else { return nil }
        let core = bundleURL.appendingPathComponent("Contents/MacOS/notch")
        return fm.isExecutableFile(atPath: core.path) ? core : nil
    }

    /// False for a bundle macOS runs from a randomized App Translocation path (a quarantined
    /// app opened where it was downloaded): that path disappears when the app quits.
    public static func isStableLocation(_ bundleURL: URL) -> Bool {
        !bundleURL.path.contains("/AppTranslocation/")
    }

    /// Re-points the hook link for the app at `bundleURL`, honouring `PLATYNOTCH_HOME`.
    public static func ensureForApp(bundleURL: URL,
                                    env: [String: String] = ProcessInfo.processInfo.environment,
                                    userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                                    fileManager fm: FileManager = .default) -> Outcome {
        guard let core = bundledCore(bundleURL: bundleURL, fileManager: fm) else {
            return .skipped("not running from an app bundle with Contents/MacOS/notch")
        }
        guard isStableLocation(bundleURL) else { return .skipped("app is translocated") }
        if (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return .skipped("app is on a read-only volume")
        }
        return ensure(link: CorePaths.hookBinary(env: env, userHome: userHome), target: core, fileManager: fm)
    }

    /// Makes `link` a symlink to `target`. A missing link, or a symlink to anything else
    /// (including a dangling one), is replaced atomically: a temporary symlink is renamed
    /// over it. A regular file is kept.
    public static func ensure(link: URL, target: URL, fileManager fm: FileManager = .default) -> Outcome {
        let dir = link.deletingLastPathComponent()
        var previous: String?
        if let attrs = try? fm.attributesOfItem(atPath: link.path) {   // does not follow symlinks
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return .keptRegularFile }
            let dest = (try? fm.destinationOfSymbolicLink(atPath: link.path)) ?? ""
            if resolve(dest, relativeTo: dir) == (target.path as NSString).standardizingPath { return .unchanged }
            previous = dest
        }
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("create \(dir.path): \(error.localizedDescription)")
        }
        // Accepted TOCTOU window: a regular file created between the check above and the
        // rename below would be replaced; only this user's own processes can write here.
        let tmp = dir.appendingPathComponent(".notch.\(UUID().uuidString).tmp")
        do {
            try fm.createSymbolicLink(atPath: tmp.path, withDestinationPath: target.path)
        } catch {
            return .failed("create symlink: \(error.localizedDescription)")
        }
        if rename(tmp.path, link.path) != 0 {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: tmp)
            return .failed("rename over \(link.path): \(reason)")
        }
        return previous.map { .repointed(from: $0) } ?? .created
    }

    private static func resolve(_ dest: String, relativeTo dir: URL) -> String {
        let absolute = dest.hasPrefix("/") ? dest : dir.appendingPathComponent(dest).path
        return (absolute as NSString).standardizingPath
    }
}
