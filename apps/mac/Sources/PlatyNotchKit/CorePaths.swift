import Foundation

/// File locations shared with the Go core (`core/paths`): `PLATYNOTCH_HOME` and
/// `PLATYNOTCH_SOCKET` redirect them the same way on both sides.
public enum CorePaths {
    public static func home(env: [String: String] = ProcessInfo.processInfo.environment,
                            userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let h = env["PLATYNOTCH_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return userHome.appendingPathComponent("Library/Application Support/PlatyNotch")
    }

    public static func socketPath(env: [String: String] = ProcessInfo.processInfo.environment,
                                  userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        if let s = env["PLATYNOTCH_SOCKET"], !s.isEmpty { return s }
        return home(env: env, userHome: userHome).appendingPathComponent("notch.sock").path
    }

    public static func coreLog(env: [String: String] = ProcessInfo.processInfo.environment,
                               userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home(env: env, userHome: userHome).appendingPathComponent("logs/core.log")
    }

    /// `PLATYNOTCH_CORE_BIN`, else `name` next to the running executable
    /// (`Contents/MacOS/notch` in the bundle, `.build/debug/notch` under `swift run`).
    public static func coreBinary(name: String,
                                  env: [String: String] = ProcessInfo.processInfo.environment,
                                  executableURL: URL? = Bundle.main.executableURL) -> URL {
        if let p = env["PLATYNOTCH_CORE_BIN"], !p.isEmpty { return URL(fileURLWithPath: p) }
        let dir = executableURL?.deletingLastPathComponent() ?? Bundle.main.bundleURL
        return dir.appendingPathComponent(name)
    }
}
