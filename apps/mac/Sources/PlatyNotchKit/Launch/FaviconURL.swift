import Foundation

/// Where a pinned site's icon may come from: its own https origin, nowhere else. Plain
/// http sites (and anything else) have no candidates and get the letter icon.
public enum FaviconURL {
    /// `https://host[:port]` (host lowercased; no user, path, query or fragment); nil
    /// unless `url` is https with a host.
    public static func origin(of url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.percentEncodedHost, !host.isEmpty else { return nil }
        c.scheme = "https"
        c.percentEncodedHost = host.lowercased()
        c.user = nil
        c.password = nil
        c.percentEncodedPath = ""
        c.query = nil
        c.fragment = nil
        if c.port == 443 { c.port = nil }
        return c.url
    }

    /// `<origin>/favicon.ico`, then `<origin>/apple-touch-icon.png`; empty for non-https.
    public static func candidates(for url: URL) -> [URL] {
        guard let o = origin(of: url) else { return [] }
        return [o.appendingPathComponent("favicon.ico"), o.appendingPathComponent("apple-touch-icon.png")]
    }

    /// Both https, the same host (any case) and the same port (443 when absent).
    public static func isSameOrigin(_ url: URL, as site: URL) -> Bool {
        guard let a = parts(url), let b = parts(site) else { return false }
        return a.host == b.host && a.port == b.port
    }

    /// The favicon session follows a redirect only within the origin it started from.
    public static func allowsRedirect(from original: URL, to target: URL) -> Bool {
        isSameOrigin(target, as: original)
    }

    /// The cache file's base name for `url`'s origin, e.g. `https_a.com_443`: only
    /// `[a-z0-9._-]`, never a path separator or a leading dot. Nil for non-https.
    public static func cacheKey(for url: URL) -> String? {
        guard let p = parts(url) else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        let host = String(p.host.map { allowed.contains($0) ? $0 : "_" })
        return "https_\(host)_\(p.port)"
    }

    private static func parts(_ url: URL) -> (host: String, port: Int)? {
        guard url.scheme?.lowercased() == "https",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.percentEncodedHost?.lowercased(), !host.isEmpty else { return nil }
        return (host, c.port ?? 443)
    }
}

/// What a favicon response must be, and how long icons and failures are remembered.
public enum FaviconPolicy {
    /// Larger bodies are refused (the download stops there).
    public static let maxBytes = 256 * 1024
    /// A saved icon is used for 30 days, then fetched again.
    public static let lifetime: TimeInterval = 30 * 86_400
    /// After a failed fetch, the site is not asked again for a day.
    public static let retryAfterFailure: TimeInterval = 86_400

    /// `image/*` except SVG (scriptable, and not needed for an icon); parameters ignored.
    public static func isImageType(_ contentType: String?) -> Bool {
        guard let raw = contentType else { return false }
        let type = raw.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return type.hasPrefix("image/") && !type.hasPrefix("image/svg")
    }

    public static func accepts(status: Int, contentType: String?, byteCount: Int) -> Bool {
        guard (200..<300).contains(status), isImageType(contentType) else { return false }
        return byteCount > 0 && byteCount <= maxBytes
    }

    /// Saved within the last 30 days (a save time in the future is not fresh).
    public static func isFresh(savedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(savedAt)
        return age >= 0 && age < lifetime
    }

    /// No failure, or the last one was over a day ago (or in the future: the clock moved).
    public static func mayRetry(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        let age = now.timeIntervalSince(lastFailure)
        return age < 0 || age >= retryAfterFailure
    }
}
