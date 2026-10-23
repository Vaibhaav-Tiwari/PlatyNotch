import Foundation

/// Finds a video-meeting join link (Google Meet, Zoom, Microsoft Teams, Webex) in calendar
/// text: the event URL, location and notes, in that order.
public enum MeetingLinks {
    /// The first join link, scanning `texts` in order and each text left to right.
    public static func firstJoinURL(in texts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        for text in texts where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                if let url = match.url, isJoinURL(url) { return url }
            }
        }
        return nil
    }

    /// Whether `url` is a meeting (not a provider's home or pricing page).
    public static func isJoinURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if host == "meet.google.com" {
            return path.range(of: #"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#, options: .regularExpression) != nil
        }
        if on("zoom.us") || on("zoomgov.com") {
            return ["/j/", "/my/", "/w/", "/s/", "/wc/join/"].contains { path.hasPrefix($0) }
        }
        if host == "teams.microsoft.com" {
            return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/")
        }
        if host == "teams.live.com" {
            return path.hasPrefix("/meet/")
        }
        if on("webex.com") {
            return path.hasSuffix("/j.php") || ["/meet/", "/join/", "/wbxmjs/", "/webappng/"].contains { path.contains($0) }
        }
        return false
    }
}
