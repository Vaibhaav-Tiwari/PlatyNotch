import Foundation

/// Finds a video-meeting join link in calendar text: the event URL, location and notes, in
/// that order. Knows Google Meet, Zoom (and ZoomGov), Microsoft Teams, Webex, FaceTime,
/// Jitsi, Whereby, Slack huddles, GoTo Meeting, Amazon Chime, BlueJeans, Skype, Discord,
/// Around, Cal.com video and Gather. Outlook Safe Links and Google redirect wrappers are
/// unwrapped first. Only https links and the meeting apps' own schemes count (plain
/// http is refused; a link typed without a scheme, "zoom.us/j/1", is read as https).
/// Finding a link never opens it: only the Join button does.
public enum MeetingLinks {
    /// The first join link in an event's URL, then location, then notes.
    public static func firstJoinURL(url: URL?, location: String?, notes: String?) -> URL? {
        firstJoinURL(in: [url?.absoluteString ?? "", location ?? "", notes ?? ""])
    }

    /// The first join link, scanning `texts` in order and each text left to right.
    public static func firstJoinURL(in texts: [String]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        for text in texts where !text.isEmpty {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard var url = match.url else { continue }
                // NSDataDetector adds "http://" to a link typed without a scheme.
                let typed = (text as NSString).substring(with: match.range).lowercased()
                if url.scheme?.lowercased() == "http", !typed.hasPrefix("http:"),
                   var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    c.scheme = "https"
                    url = c.url ?? url
                }
                let found = unwrap(url)
                if isJoinURL(found) { return found }
            }
        }
        return nil
    }

    /// The link inside a Safe Links / Google redirect wrapper (two levels at most), else `url`.
    public static func unwrap(_ url: URL) -> URL {
        var current = url
        for _ in 0..<2 {
            guard let host = current.host?.lowercased(),
                  let items = URLComponents(url: current, resolvingAgainstBaseURL: false)?.queryItems else { break }
            let key: String? = if host.hasSuffix(".safelinks.protection.outlook.com") { "url" }
                else if (host == "www.google.com" || host == "google.com"), current.path == "/url" { "q" }
                else { nil }
            guard let key, let inner = items.first(where: { $0.name == key })?.value, let next = URL(string: inner),
                  next.scheme != nil else { break }
            current = next
        }
        return current
    }

    /// Meeting apps' own link schemes (they open only that app).
    public static let appSchemes: Set<String> = ["zoommtg", "zoomus", "msteams", "webex", "wbx", "facetime"]

    /// Whether `url` is a meeting (not a provider's home or pricing page): https only, or
    /// a meeting app's own scheme.
    public static func isJoinURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if appSchemes.contains(scheme) { return true }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let segments = path.split(separator: "/").map(String.init)
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        func matches(_ pattern: String) -> Bool { path.range(of: pattern, options: .regularExpression) != nil }

        if host == "meet.google.com" { return matches(#"^/[a-z]{3}-[a-z]{4}-[a-z]{3}$"#) }
        if on("zoom.us") || on("zoomgov.com") {
            return ["/j/", "/my/", "/w/", "/s/", "/wc/join/"].contains { path.hasPrefix($0) }
        }
        if host == "teams.microsoft.com" { return path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") }
        if host == "teams.live.com" { return path.hasPrefix("/meet/") }
        if on("webex.com") {
            return path.hasSuffix("/j.php") || ["/meet/", "/join/", "/wbxmjs/", "/webappng/"].contains { path.contains($0) }
        }
        switch host {
        case "facetime.apple.com": return path.hasPrefix("/join")
        case "meet.jit.si": return segments.count == 1
        case "whereby.com":
            let reserved: Set = ["pricing", "information", "login", "signup", "user", "org", "blog", "embed", "legal", "about"]
            return segments.count == 1 && !reserved.contains(segments[0])
        case "app.slack.com": return path.hasPrefix("/huddle/")
        case "meet.goto.com": return matches(#"^/\d{6,}$"#)
        case "global.gotomeeting.com", "app.gotomeeting.com": return path.hasPrefix("/join/")
        case "chime.aws": return matches(#"^/\d{10}$"#)
        case "bluejeans.com": return matches(#"^/\d{5,}(/\d+)?$"#)
        case "join.skype.com": return segments.count == 1
        case "discord.gg": return segments.count == 1
        case "around.co": return path.hasPrefix("/r/")
        case "cal.com", "app.cal.com": return path.hasPrefix("/video/")
        case "app.gather.town": return path.hasPrefix("/app/")
        default: return false
        }
    }
}
