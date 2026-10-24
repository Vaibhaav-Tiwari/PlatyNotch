import Foundation
import PlatyNotchKit
import XCTest

/// Pinned sites, favicon URLs and policy, browser scripts and the Shortcuts CLI (Task 11).
/// Imports Kit without `@testable`: everything the UI uses must be public (C6).
final class LaunchTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Favicon URLs

    func testFaviconCandidatesUseOrigin() {
        XCTAssertEqual(FaviconURL.candidates(for: url("https://a.com/x/y?z")),
                       [url("https://a.com/favicon.ico"), url("https://a.com/apple-touch-icon.png")])
        XCTAssertEqual(FaviconURL.candidates(for: url("https://user@a.com:8443/p#f")).first,
                       url("https://a.com:8443/favicon.ico"), "keeps the port, drops user, path and fragment")
        XCTAssertEqual(FaviconURL.candidates(for: url("https://A.COM/")).first, url("https://a.com/favicon.ico"))
    }

    func testFaviconCandidatesHttpsOnly() {
        XCTAssertEqual(FaviconURL.candidates(for: url("http://a.com/x")), [], "plain http gets the letter icon")
        XCTAssertEqual(FaviconURL.candidates(for: url("file:///etc/hosts")), [])
        XCTAssertEqual(FaviconURL.candidates(for: url("ftp://a.com/")), [])
        XCTAssertNil(FaviconURL.origin(of: url("http://a.com")))
    }

    func testSameOrigin() {
        let site = url("https://a.com/page")
        XCTAssertTrue(FaviconURL.isSameOrigin(url("https://a.com/favicon.ico"), as: site))
        XCTAssertTrue(FaviconURL.isSameOrigin(url("https://A.com:443/x"), as: site), "default port, any case")
        XCTAssertFalse(FaviconURL.isSameOrigin(url("https://cdn.a.com/favicon.ico"), as: site), "subdomain is another origin")
        XCTAssertFalse(FaviconURL.isSameOrigin(url("https://evil.com/favicon.ico"), as: site))
        XCTAssertFalse(FaviconURL.isSameOrigin(url("http://a.com/favicon.ico"), as: site), "downgrade refused")
        XCTAssertFalse(FaviconURL.isSameOrigin(url("https://a.com:8443/favicon.ico"), as: site), "other port")
        XCTAssertFalse(FaviconURL.isSameOrigin(url("https://a.com.evil.com/"), as: site))
        XCTAssertTrue(FaviconURL.allowsRedirect(from: url("https://a.com/favicon.ico"), to: url("https://a.com/static/f.ico")))
        XCTAssertFalse(FaviconURL.allowsRedirect(from: url("https://a.com/favicon.ico"), to: url("https://cdn.b.com/f.ico")))
    }

    func testCacheKeyIsSanitisedAndPerOrigin() throws {
        let key = try XCTUnwrap(FaviconURL.cacheKey(for: url("https://Docs.A.com/x/y?q=1")))
        XCTAssertEqual(key, "https_docs.a.com_443")
        XCTAssertEqual(FaviconURL.cacheKey(for: url("https://docs.a.com/other")), key, "one entry per origin")
        XCTAssertEqual(FaviconURL.cacheKey(for: url("https://a.com:8443/")), "https_a.com_8443")
        XCTAssertNil(FaviconURL.cacheKey(for: url("http://a.com/")))
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-")
        for raw in ["https://xn--bcher-kva.de/", "https://a.com%2F..%2F..%2Fetc/", "https://[::1]:9/"] {
            guard let u = URL(string: raw), let k = FaviconURL.cacheKey(for: u) else { continue }
            XCTAssertTrue(k.allSatisfy { allowed.contains($0) }, k)
            XCTAssertFalse(k.contains("/") || k.hasPrefix("."), k)
        }
    }

    func testFaviconsFolderFollowsHome() {
        let home = URL(fileURLWithPath: "/Users/me")
        XCTAssertEqual(CorePaths.favicons(env: [:], userHome: home).path,
                       "/Users/me/Library/Application Support/PlatyNotch/favicons")
        XCTAssertEqual(CorePaths.favicons(env: ["PLATYNOTCH_HOME": "/tmp/pn"], userHome: home).path, "/tmp/pn/favicons")
    }

    // MARK: - Favicon policy

    func testFaviconResponseCaps() {
        XCTAssertTrue(FaviconPolicy.accepts(status: 200, contentType: "image/x-icon", byteCount: 1_000))
        XCTAssertTrue(FaviconPolicy.accepts(status: 200, contentType: "Image/PNG; charset=binary", byteCount: 10))
        XCTAssertFalse(FaviconPolicy.accepts(status: 200, contentType: "text/html", byteCount: 10), "not an image")
        XCTAssertFalse(FaviconPolicy.accepts(status: 200, contentType: nil, byteCount: 10), "no type")
        XCTAssertFalse(FaviconPolicy.accepts(status: 200, contentType: "image/svg+xml", byteCount: 10), "SVG refused")
        XCTAssertFalse(FaviconPolicy.accepts(status: 404, contentType: "image/png", byteCount: 10))
        XCTAssertFalse(FaviconPolicy.accepts(status: 200, contentType: "image/png", byteCount: 0), "empty")
        XCTAssertTrue(FaviconPolicy.accepts(status: 200, contentType: "image/png", byteCount: FaviconPolicy.maxBytes))
        XCTAssertFalse(FaviconPolicy.accepts(status: 200, contentType: "image/png", byteCount: FaviconPolicy.maxBytes + 1),
                       "over the size cap")
        XCTAssertEqual(FaviconPolicy.maxBytes, 256 * 1024)
    }

    func testFaviconFreshnessAndRetry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        XCTAssertTrue(FaviconPolicy.isFresh(savedAt: now.addingTimeInterval(-29 * day), now: now))
        XCTAssertFalse(FaviconPolicy.isFresh(savedAt: now.addingTimeInterval(-30 * day - 1), now: now), "30 days")
        XCTAssertFalse(FaviconPolicy.isFresh(savedAt: now.addingTimeInterval(2 * day), now: now), "clock went back")
        XCTAssertTrue(FaviconPolicy.mayRetry(lastFailure: nil, now: now))
        XCTAssertFalse(FaviconPolicy.mayRetry(lastFailure: now.addingTimeInterval(-3600), now: now), "once a day")
        XCTAssertTrue(FaviconPolicy.mayRetry(lastFailure: now.addingTimeInterval(-day - 1), now: now))
    }

    // MARK: - Site URLs

    func testSiteURLOpensOnlyHttpAndHttps() {
        XCTAssertEqual(SiteURL.parse("https://a.com/x"), url("https://a.com/x"))
        XCTAssertEqual(SiteURL.parse("  http://a.com  "), url("http://a.com"))
        XCTAssertEqual(SiteURL.parse("a.com/path"), url("https://a.com/path"), "no scheme: https")
        XCTAssertEqual(SiteURL.parse("localhost:3000"), url("https://localhost:3000"), "host:port is not a scheme")
        for bad in ["javascript:alert(1)", "JAVASCRIPT:alert(1)", "file:///etc/passwd", "data:text/html,hi",
                    "mailto:a@b.c", "ftp://a.com", "x-apple.systempreferences:com.apple", "platynotch://pair",
                    "vbscript:x", "", "   ", "https://", "https://user:pw@a.com/", "https://a b.com"] {
            XCTAssertNil(SiteURL.parse(bad), bad)
        }
        XCTAssertFalse(SiteURL.isOpenable(url("file:///tmp")))
        XCTAssertFalse(SiteURL.isOpenable(url("javascript:alert(1)")))
        XCTAssertTrue(SiteURL.isOpenable(url("HTTPS://a.com")))
        XCTAssertNil(SiteURL.parse("https://a.com/" + String(repeating: "x", count: 5000)), "too long")
    }

    func testSiteTitleAndLetter() {
        XCTAssertEqual(SiteURL.defaultTitle(for: url("https://www.github.com/x")), "github.com")
        let s = PinnedSite(title: "github.com", url: url("https://github.com"))
        XCTAssertEqual(SiteURL.letter(for: s), "G")
        XCTAssertEqual(SiteURL.letter(for: PinnedSite(title: "  ", url: url("https://x.org"))), "X")
    }

    // MARK: - Pins

    func testPinnedSiteCodable() throws {
        let s = PinnedSite(id: UUID(), title: "A", url: url("https://a.com/x"))
        let back = try JSONDecoder().decode(PinnedSite.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        let pins = LaunchPins(sites: [s], shortcuts: [PinnedShortcut(name: "Focus 25")])
        XCTAssertEqual(try JSONDecoder().decode(LaunchPins.self, from: JSONEncoder().encode(pins)), pins)
    }

    func testPinLimitsAndDuplicates() {
        var p = LaunchPins()
        for i in 0..<LaunchPins.maxSites {
            XCTAssertEqual(p.addSite(url("https://s\(i).com")), .added)
        }
        XCTAssertEqual(p.addSite(url("https://more.com")), .full)
        XCTAssertEqual(p.sites.count, 12)
        var q = LaunchPins()
        XCTAssertEqual(q.addSite(url("https://a.com")), .added)
        XCTAssertEqual(q.addSite(url("https://A.com/")), .duplicate)
        XCTAssertEqual(q.addSite(url("javascript:alert(1)")), .invalid)
        XCTAssertEqual(q.addSite(url("file:///etc")), .invalid)
        for i in 0..<LaunchPins.maxShortcuts { XCTAssertEqual(q.addShortcut("S\(i)"), .added) }
        XCTAssertEqual(q.addShortcut("S9"), .full)
        XCTAssertEqual(q.addShortcut("S1"), .duplicate)
        XCTAssertEqual(q.addShortcut("  "), .invalid)
        XCTAssertEqual(q.shortcuts.count, 8)
        q.removeShortcut(id: q.shortcuts[0].id)
        XCTAssertEqual(q.shortcuts.count, 7)
    }

    func testMoveAndRemoveSite() {
        var p = LaunchPins()
        _ = p.addSite(url("https://a.com"))
        _ = p.addSite(url("https://b.com"))
        _ = p.addSite(url("https://c.com"))
        p.moveSite(id: p.sites[2].id, to: 0)
        XCTAssertEqual(p.sites.map(\.title), ["c.com", "a.com", "b.com"])
        p.moveSite(id: p.sites[0].id, to: 99)
        XCTAssertEqual(p.sites.map(\.title), ["a.com", "b.com", "c.com"])
        p.removeSite(id: p.sites[1].id)
        XCTAssertEqual(p.sites.map(\.title), ["a.com", "c.com"])
    }

    func testLoadDropsUnsafeAndOverLimit() throws {
        let name = "LaunchTests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        XCTAssertEqual(LaunchPins.load(from: d), LaunchPins(), "nothing saved")
        var sites = [PinnedSite(title: "bad", url: url("javascript:alert(1)"))]
        sites += (0..<20).map { PinnedSite(title: "s\($0)", url: url("https://s\($0).com")) }
        let shortcuts = (0..<10).map { PinnedShortcut(name: "S\($0)") }
        d.set(try JSONEncoder().encode(LaunchPins(sites: sites, shortcuts: shortcuts)), forKey: LaunchPins.defaultsKey)
        let loaded = LaunchPins.load(from: d)
        XCTAssertEqual(loaded.sites.count, 12)
        XCTAssertFalse(loaded.sites.contains { $0.title == "bad" })
        XCTAssertEqual(loaded.shortcuts.count, 8)
        var p = LaunchPins()
        _ = p.addSite(url("https://a.com"))
        p.save(to: d)
        XCTAssertEqual(LaunchPins.load(from: d), p)
        d.set(Data("garbage".utf8), forKey: LaunchPins.defaultsKey)
        XCTAssertEqual(LaunchPins.load(from: d), LaunchPins(), "unreadable → empty")
    }

    // MARK: - Browsers

    func testBrowserScriptsAreConstantPerBrowser() {
        XCTAssertTrue(SupportedBrowser.safari.script.contains("URL of current tab of front window"))
        XCTAssertFalse(SupportedBrowser.safari.script.contains("active tab"))
        for b in [SupportedBrowser.chrome, .arc] {
            XCTAssertTrue(b.script.contains("URL of active tab of front window"), b.name)
        }
        for b in SupportedBrowser.allCases {
            XCTAssertTrue(b.script.contains("application id \"\(b.rawValue)\" is not running"), "never launches \(b.name)")
            XCTAssertTrue(b.script.contains("with timeout of"), b.name)
            XCTAssertFalse(b.script.contains("activate"), b.name)
        }
        XCTAssertEqual(SupportedBrowser.allCases.map(\.rawValue),
                       ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser"])
    }

    func testBrowserPick() {
        let all: Set<String> = ["com.apple.Safari", "company.thebrowser.Browser"]
        XCTAssertEqual(SupportedBrowser.pick(frontmost: "company.thebrowser.Browser", running: all), .arc, "frontmost first")
        XCTAssertEqual(SupportedBrowser.pick(frontmost: "com.apple.Terminal", running: all), .safari, "then list order")
        XCTAssertNil(SupportedBrowser.pick(frontmost: "com.apple.Safari", running: []), "frontmost but not running")
        XCTAssertNil(SupportedBrowser.pick(frontmost: nil, running: ["org.mozilla.firefox"]))
    }

    func testSettingsWindowUsesTheLastOtherApp() {
        let safari = SupportedBrowser.safari.rawValue
        XCTAssertEqual(SupportedBrowser.effectiveFrontmost(current: "dev.platynotch.app", currentIsSelf: true, previous: safari),
                       safari, "PlatyNotch's Settings window is active: the browser before it")
        XCTAssertEqual(SupportedBrowser.effectiveFrontmost(current: "com.google.Chrome", currentIsSelf: false, previous: safari),
                       "com.google.Chrome")
        XCTAssertNil(SupportedBrowser.effectiveFrontmost(current: nil, currentIsSelf: true, previous: nil))
        let front = SupportedBrowser.effectiveFrontmost(current: nil, currentIsSelf: true, previous: "company.thebrowser.Browser")
        XCTAssertEqual(SupportedBrowser.pick(frontmost: front, running: [safari, "company.thebrowser.Browser"]), .arc)
    }

    // MARK: - Shortcuts

    func testShortcutsArgumentsNeverParseTheNameAsAnOption() {
        XCTAssertEqual(ShortcutsCLI.path, "/usr/bin/shortcuts")
        XCTAssertEqual(ShortcutsCLI.listArguments, ["list"])
        XCTAssertEqual(ShortcutsCLI.runArguments("--help; rm -rf ~"), ["run", "--", "--help; rm -rf ~"],
                       "one argv element after the terminator, no shell")
    }

    func testShortcutsListParse() {
        let out = "Focus 25\n\n  Make GIF  \nFocus 25\r\nLog water\n"
        XCTAssertEqual(ShortcutsCLI.parseList(out), ["Focus 25", "Make GIF", "Log water"])
        let many = (0..<900).map { "S\($0)" }.joined(separator: "\n")
        XCTAssertEqual(ShortcutsCLI.parseList(many).count, ShortcutsCLI.maxNames)
    }

    func testShortcutOutcome() {
        XCTAssertEqual(ShortcutOutcome.from(status: 0, timedOut: false, cancelled: false), .done)
        XCTAssertEqual(ShortcutOutcome.from(status: 1, timedOut: false, cancelled: false), .failed(1))
        XCTAssertEqual(ShortcutOutcome.from(status: 9, timedOut: true, cancelled: false), .timedOut)
        XCTAssertEqual(ShortcutOutcome.from(status: 15, timedOut: false, cancelled: true), .cancelled)
        XCTAssertEqual(ShortcutOutcome.done.message(for: "Log"), "“Log” done")
        XCTAssertEqual(ShortcutOutcome.failed(3).message(for: "Log"), "“Log” failed (exit 3)")
        XCTAssertTrue(ShortcutOutcome.timedOut.message(for: "Log").contains("stopped after 60 s"))
        XCTAssertFalse(ShortcutOutcome.failed(1).succeeded)
        XCTAssertTrue(ShortcutOutcome.done.succeeded)
    }
}
