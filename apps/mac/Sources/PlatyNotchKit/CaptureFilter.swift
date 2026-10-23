import Foundation

/// Decides whether an on-screen text capture is sent to the core.
public struct CaptureFilter: Sendable {
    /// Shorter captures (after trimming) carry nothing worth remembering.
    public static let minChars = 20
    /// Never captured, whatever the config says: PlatyNotch itself and the login window.
    public static let alwaysExcluded: Set<String> = ["dev.platynotch.app", "com.apple.loginwindow"]

    public let excluded: Set<String>

    public init(excluded: Set<String>) {
        self.excluded = excluded.union(Self.alwaysExcluded)
    }

    public func isExcluded(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return true }
        return excluded.contains(bundleID)
    }

    /// False for an excluded or unknown app, while secure input is on (a password is being
    /// typed somewhere), for short text, and for text unchanged since the last capture.
    public func shouldCapture(bundleID: String?, secureInput: Bool, text: String, lastHash: Int?) -> Bool {
        if isExcluded(bundleID) || secureInput { return false }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < Self.minChars { return false }
        return lastHash != Self.hash(text)
    }

    /// Stable within one process run (used only to skip unchanged text).
    public static func hash(_ text: String) -> Int { text.hashValue }

    /// Windows never captured even though their app is: System Settings' password panes.
    public static func isSensitiveWindow(bundleID: String?, title: String?) -> Bool {
        guard bundleID == "com.apple.systempreferences", let title else { return false }
        return title.range(of: "password", options: .caseInsensitive) != nil
    }

    public static func envelope(appBundle: String, appName: String, windowTitle: String?, url: String?,
                                text: String, at: Date) throws -> Envelope {
        try Envelope.make(.captureText, CaptureText(appBundle: appBundle, appName: appName, windowTitle: windowTitle,
                                                    url: url, text: text, capturedAt: at))
    }
}

/// Accumulates the strings found while walking an accessibility tree, within the
/// element and character limits.
public struct AXTextCollector: Sendable {
    public let maxChars: Int
    public let maxElements: Int
    public private(set) var visited = 0
    private var parts: [String] = []
    private var chars = 0
    private var last: String?

    public init(maxChars: Int, maxElements: Int) {
        self.maxChars = max(0, maxChars)
        self.maxElements = max(0, maxElements)
    }

    public var isFull: Bool { chars >= maxChars || visited >= maxElements }
    public var text: String { parts.joined(separator: "\n") }

    /// Counts one element; false once the element limit is reached.
    public mutating func visit() -> Bool {
        guard visited < maxElements else { return false }
        visited += 1
        return true
    }

    public mutating func add(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != last, chars < maxChars else { return }
        last = s
        let sep = parts.isEmpty ? 0 : 1
        let room = maxChars - chars - sep
        guard room > 0 else { chars = maxChars; return }
        let piece = s.count > room ? String(s.prefix(room)) : s
        parts.append(piece)
        chars += piece.count + sep
    }

    /// `AXSecureTextField` as a role or subrole: its value is never read.
    public static func isSecure(role: String?, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }
}

/// What the capture service is doing, for the Memory tab and the menu bar dot.
public enum CaptureStatus: Sendable, Equatable {
    case off
    case needsAccessibility
    case paused(until: Date)
    case capturing

    public var isCapturing: Bool { self == .capturing }

    public static func resolve(enabled: Bool, trusted: Bool, pausedUntil: Date?, now: Date) -> CaptureStatus {
        guard enabled else { return .off }
        guard trusted else { return .needsAccessibility }
        if let pausedUntil, pausedUntil > now { return .paused(until: pausedUntil) }
        return .capturing
    }
}

/// The `memory` section of `config.json` that capture needs. A read-only mirror of the
/// Go `config.Memory` defaults; replaced by the full config store in the Settings task.
public struct CaptureSettings: Sendable, Equatable {
    public static let defaultIntervalSeconds = 20
    public static let defaultExcludeApps = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.apple.keychainaccess", "com.bitwarden.desktop",
        "com.apple.Passwords", "com.lastpass.LastPass",
    ]

    public var enabled: Bool
    public var intervalSeconds: Int
    public var excludeApps: [String]

    public init(enabled: Bool = false, intervalSeconds: Int = Self.defaultIntervalSeconds,
                excludeApps: [String] = Self.defaultExcludeApps) {
        self.enabled = enabled; self.intervalSeconds = intervalSeconds; self.excludeApps = excludeApps
    }

    private struct File: Decodable {
        var memory: Memory?
        struct Memory: Decodable {
            var enabled: Bool?
            var captureIntervalSeconds: Int?
            var excludeApps: [String]?
            enum CodingKeys: String, CodingKey {
                case enabled
                case captureIntervalSeconds = "capture_interval_seconds"
                case excludeApps = "exclude_apps"
            }
        }
    }

    /// Like Go's `config.LoadFile`: a missing or unreadable file gives the defaults
    /// (memory off); missing fields keep their defaults; an interval <= 0 becomes 20.
    public static func read(from url: URL) -> CaptureSettings {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return CaptureSettings() }
        var s = CaptureSettings()
        guard let m = file.memory else { return s }
        if let e = m.enabled { s.enabled = e }
        if let i = m.captureIntervalSeconds { s.intervalSeconds = i > 0 ? i : Self.defaultIntervalSeconds }
        if let x = m.excludeApps { s.excludeApps = x }
        return s
    }
}
