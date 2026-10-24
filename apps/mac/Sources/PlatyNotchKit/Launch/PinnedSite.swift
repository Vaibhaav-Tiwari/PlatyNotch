import Foundation

/// A site pinned to the launch tile. Opens in the default browser; only http and https
/// (`SiteURL.isOpenable`), checked when pinned, when loaded and again when opened.
public struct PinnedSite: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL

    public init(id: UUID = UUID(), title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }
}

/// A Shortcuts shortcut pinned to the launch tile, run by name on click
/// (`/usr/bin/shortcuts run -- <name>`, `ShortcutsCLI`).
public struct PinnedShortcut: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// What a pinned site may be: an http or https URL with a host and no user or password.
/// `file:`, `javascript:`, `data:`, `mailto:` and every custom scheme are refused.
public enum SiteURL {
    public static let schemes: Set<String> = ["http", "https"]
    public static let maxLength = 2048

    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return false }
        guard let host = url.host, !host.isEmpty else { return false }
        if url.user != nil || url.password != nil { return false }
        return url.absoluteString.count <= maxLength
    }

    /// A typed or scripted address: trimmed; `https://` is added when there is no scheme
    /// (`a.com/x`, `localhost:3000`). Nil when the result is not openable.
    public static func parse(_ text: String) -> URL? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= maxLength else { return nil }
        guard !s.contains(where: { $0.isWhitespace }) else { return nil }
        let full = hasScheme(s) ? s : "https://" + s
        guard let url = URL(string: full, encodingInvalidCharacters: false), isOpenable(url) else { return nil }
        return url
    }

    /// True when `s` starts with a scheme (`x:` that is not `host:port`).
    private static func hasScheme(_ s: String) -> Bool {
        if s.contains("://") { return true }
        guard let colon = s.firstIndex(of: ":") else { return false }
        let head = s[..<colon]
        if head.contains("/") { return false }
        let rest = s[s.index(after: colon)...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        let afterPort = rest.dropFirst(digits.count)
        let isPort = !digits.isEmpty && (afterPort.isEmpty || afterPort.hasPrefix("/"))
        return !isPort
    }

    /// The host without a leading `www.`.
    public static func defaultTitle(for url: URL) -> String {
        let host = (url.host ?? url.absoluteString).lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The letter icon: the first letter or digit of the title, else of the host.
    public static func letter(for site: PinnedSite) -> String {
        let sources = [site.title, defaultTitle(for: site.url)]
        for text in sources {
            if let c = text.first(where: { $0.isLetter || $0.isNumber }) { return String(c).uppercased() }
        }
        return "•"
    }

    /// One identity per address: scheme and host lowercased, an empty path is "/", no fragment.
    public static func identity(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.scheme = c.scheme?.lowercased()
        c.percentEncodedHost = c.percentEncodedHost?.lowercased()
        if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
        c.fragment = nil
        return c.string ?? url.absoluteString
    }
}

/// The pinned sites and shortcuts, saved as one Codable value in `UserDefaults.standard`
/// under `defaultsKey`. At most `maxSites` sites and `maxShortcuts` shortcuts.
public struct LaunchPins: Codable, Equatable, Sendable {
    public static let maxSites = 12
    public static let maxShortcuts = 8
    public static let maxNameLength = 255
    public static let defaultsKey = "launch.pins"

    public var sites: [PinnedSite]
    public var shortcuts: [PinnedShortcut]

    public init(sites: [PinnedSite] = [], shortcuts: [PinnedShortcut] = []) {
        self.sites = sites
        self.shortcuts = shortcuts
    }

    public enum AddResult: Equatable, Sendable {
        case added, duplicate, full, invalid
    }

    @discardableResult
    public mutating func addSite(_ url: URL, title: String? = nil) -> AddResult {
        guard SiteURL.isOpenable(url) else { return .invalid }
        let identity = SiteURL.identity(url)
        if sites.contains(where: { SiteURL.identity($0.url) == identity }) { return .duplicate }
        guard sites.count < Self.maxSites else { return .full }
        let given = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        sites.append(PinnedSite(title: given.isEmpty ? SiteURL.defaultTitle(for: url) : given, url: url))
        return .added
    }

    public mutating func removeSite(id: UUID) {
        sites.removeAll { $0.id == id }
    }

    /// Moves a site to `index` (clamped).
    public mutating func moveSite(id: UUID, to index: Int) {
        guard let from = sites.firstIndex(where: { $0.id == id }) else { return }
        let site = sites.remove(at: from)
        sites.insert(site, at: min(max(index, 0), sites.count))
    }

    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maxNameLength && !trimmed.contains(where: \.isNewline)
    }

    @discardableResult
    public mutating func addShortcut(_ name: String) -> AddResult {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidName(trimmed) else { return .invalid }
        if shortcuts.contains(where: { $0.name == trimmed }) { return .duplicate }
        guard shortcuts.count < Self.maxShortcuts else { return .full }
        shortcuts.append(PinnedShortcut(name: trimmed))
        return .added
    }

    public mutating func removeShortcut(id: UUID) {
        shortcuts.removeAll { $0.id == id }
    }

    /// The saved pins, minus anything unsafe or over the limits; empty when unreadable.
    public static func load(from defaults: UserDefaults) -> LaunchPins {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(LaunchPins.self, from: data) else { return LaunchPins() }
        let sites = saved.sites.filter { SiteURL.isOpenable($0.url) }.prefix(maxSites)
        let shortcuts = saved.shortcuts.filter { isValidName($0.name) }.prefix(maxShortcuts)
        return LaunchPins(sites: Array(sites), shortcuts: Array(shortcuts))
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Browsers whose current tab "Add current tab" can read with AppleScript. Each script is
/// a constant (nothing is spliced in), returns "" when the browser is not running or has
/// no window (so it never launches one), and gives up after 5 s.
public enum SupportedBrowser: String, CaseIterable, Sendable {
    case safari = "com.apple.Safari"
    case chrome = "com.google.Chrome"
    case arc = "company.thebrowser.Browser"

    public var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .arc: "Arc"
        }
    }

    public var script: String {
        switch self {
        case .safari: Self.safariScript
        case .chrome: Self.chromeScript
        case .arc: Self.arcScript
        }
    }

    /// Safari names the tab `current tab`.
    static let safariScript = """
    if application id "com.apple.Safari" is not running then return ""
    with timeout of 5 seconds
        tell application id "com.apple.Safari"
            if (count of windows) is 0 then return ""
            return URL of current tab of front window
        end tell
    end timeout
    """

    /// Chrome and Arc name it `active tab`.
    static let chromeScript = """
    if application id "com.google.Chrome" is not running then return ""
    with timeout of 5 seconds
        tell application id "com.google.Chrome"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
    end timeout
    """

    static let arcScript = """
    if application id "company.thebrowser.Browser" is not running then return ""
    with timeout of 5 seconds
        tell application id "company.thebrowser.Browser"
            if (count of windows) is 0 then return ""
            return URL of active tab of front window
        end tell
    end timeout
    """

    /// The app to treat as frontmost: `current`, unless that is PlatyNotch itself (its
    /// Settings window is active), then the last other app that was active.
    public static func effectiveFrontmost(current: String?, currentIsSelf: Bool, previous: String?) -> String? {
        currentIsSelf || current == nil ? previous : current
    }

    /// The frontmost app when it is a running supported browser, else the first running
    /// one in `allCases` order; nil when none runs.
    public static func pick(frontmost: String?, running: Set<String>) -> SupportedBrowser? {
        if let f = frontmost, running.contains(f), let b = SupportedBrowser(rawValue: f) { return b }
        return allCases.first { running.contains($0.rawValue) }
    }
}
