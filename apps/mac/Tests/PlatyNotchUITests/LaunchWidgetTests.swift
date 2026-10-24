import AppKit
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// The launch widget's network, process and script gates with fakes: no real network,
/// AppleScript or Shortcuts. Favicons go to a temp directory, never the real
/// ~/Library/Application Support/PlatyNotch.
@MainActor
final class LaunchWidgetTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []
    nonisolated(unsafe) private var dirs: [URL] = []

    override func tearDown() {
        for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        suites = []
        dirs = []
        super.tearDown()
    }

    // MARK: - Fakes

    final class FakeFetcher: FaviconFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var _requested: [URL] = []
        var respond: @Sendable (URL) throws -> FaviconResponse

        init(respond: @escaping @Sendable (URL) throws -> FaviconResponse = FakeFetcher.png) {
            self.respond = respond
        }

        var requested: [URL] {
            lock.lock(); defer { lock.unlock() }
            return _requested
        }

        func fetch(_ url: URL) async throws -> FaviconResponse {
            lock.withLock { _requested.append(url) }
            return try respond(url)
        }

        @Sendable static func png(_ url: URL) throws -> FaviconResponse {
            FaviconResponse(url: url, status: 200, contentType: "image/png", data: LaunchWidgetTests.pngData)
        }
    }

    final class FakeTabs: BrowserTabReading, @unchecked Sendable {
        var calls = 0
        var result: TabReadResult = .noBrowser
        @MainActor func currentTab() async -> TabReadResult {
            calls += 1
            return result
        }
    }

    final class FakeShortcuts: ShortcutsRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var _lists = 0
        private var _runs: [String] = []
        var names: [String]? = ["Log water", "Focus 25"]
        var outcome: ShortcutOutcome = .done
        var hang = false

        var lists: Int { lock.lock(); defer { lock.unlock() }; return _lists }
        var runs: [String] { lock.lock(); defer { lock.unlock() }; return _runs }

        func list() async -> [String]? {
            lock.withLock { _lists += 1 }
            return names
        }

        func run(_ name: String) async -> ShortcutOutcome {
            lock.withLock { _runs.append(name) }
            if hang {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                return .cancelled
            }
            return outcome
        }
    }

    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    nonisolated static let pngData: Data = {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }()

    // MARK: - Rig

    private struct Rig {
        let widget: LaunchWidget
        let fetcher: FakeFetcher
        let tabs: FakeTabs
        let shortcuts: FakeShortcuts
        let dir: URL
        let defaults: UserDefaults
        let clock: Clock
        var opened: () -> [URL]
    }

    private func defaults() -> UserDefaults {
        let name = "LaunchWidgetTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnlaunch\(UUID().uuidString)")
        dirs.append(d)
        return d.appendingPathComponent("favicons", isDirectory: true)
    }

    private func rig(fetcher: FakeFetcher = FakeFetcher(), defaults d: UserDefaults? = nil, dir: URL? = nil,
                     clock: Clock = Clock()) -> Rig {
        let d = d ?? defaults()
        let dir = dir ?? tempDir()
        let tabs = FakeTabs()
        let shortcuts = FakeShortcuts()
        nonisolated(unsafe) var opened: [URL] = []
        let w = LaunchWidget(defaults: d, faviconDirectory: dir, fetcher: { fetcher }, shortcuts: shortcuts, tabs: tabs,
                             open: { opened.append($0); return true }, clock: { clock.now })
        return Rig(widget: w, fetcher: fetcher, tabs: tabs, shortcuts: shortcuts, dir: dir, defaults: d, clock: clock,
                   opened: { opened })
    }

    private func context() -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnlaunchctx\(UUID().uuidString)")
        dirs.append(dir)
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), notify: NoopNotifier(), surfaces: PanelSurfaces(), openPanel: { _ in })
    }

    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 5) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func savePins(_ d: UserDefaults, _ urls: [String], shortcuts: [String] = []) {
        var p = LaunchPins()
        for u in urls { p.addSite(URL(string: u)!) }
        for s in shortcuts { p.addShortcut(s) }
        p.save(to: d)
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    // MARK: - Disabled does no work

    func testNeverStartedDoesNothing() async {
        let d = defaults()
        savePins(d, ["https://a.com", "https://b.com"], shortcuts: ["Log water"])
        let r = rig(defaults: d)
        XCTAssertEqual(r.widget.pins.sites.count, 2, "pins load without starting")
        r.widget.refreshIcons()
        r.widget.addCurrentTab()
        r.widget.openPicker()
        r.widget.run(r.widget.pins.shortcuts[0])
        r.widget.open(r.widget.pins.sites[0])
        XCTAssertFalse(r.widget.pin(URL(string: "https://c.com")!))
        await settle()
        XCTAssertEqual(r.fetcher.requested, [], "no network")
        XCTAssertEqual(r.tabs.calls, 0, "no Apple Event")
        XCTAssertEqual(r.shortcuts.lists, 0, "no process")
        XCTAssertEqual(r.shortcuts.runs, [])
        XCTAssertEqual(r.opened(), [])
        XCTAssertNil(r.widget.cache, "no session made")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.path))
    }

    func testStartWithNothingPinnedDoesNoNetwork() async {
        let r = rig()
        r.widget.start(context: context())
        await settle()
        await r.widget.iconsSettled()
        XCTAssertEqual(r.fetcher.requested, [])
        XCTAssertEqual(r.tabs.calls, 0)
        XCTAssertEqual(r.shortcuts.lists, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.path))
        XCTAssertTrue(r.widget.defaultEnabled)
        r.widget.stop()
    }

    func testStopCancelsARunningShortcut() async {
        let d = defaults()
        savePins(d, [], shortcuts: ["Slow"])
        let r = rig(defaults: d)
        r.shortcuts.hang = true
        r.widget.start(context: context())
        r.widget.run(r.widget.pins.shortcuts[0])
        await waitFor { r.shortcuts.runs.count == 1 }
        r.widget.stop()
        XCTAssertNil(r.widget.runningShortcut)
    }

    // MARK: - Favicon network gate

    func testPinFetchesOnlyThePinnedOrigin() async throws {
        let r = rig()
        r.widget.start(context: context())
        XCTAssertTrue(r.widget.pin(URL(string: "https://a.com/x/y?z")!))
        await r.widget.iconsSettled()
        XCTAssertEqual(r.fetcher.requested, [URL(string: "https://a.com/favicon.ico")!])
        let site = try XCTUnwrap(r.widget.pins.sites.first)
        XCTAssertNotNil(r.widget.icon(for: site))
        let file = r.dir.appendingPathComponent("https_a.com_443.icon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(mode(r.dir), 0o700)
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertTrue(PrivateFolder.isMarked(r.dir))
        r.widget.stop()
    }

    func testHttpSiteGetsLetterWithoutFetch() async throws {
        let r = rig()
        r.widget.start(context: context())
        XCTAssertTrue(r.widget.pin(URL(string: "http://intranet.example/")!))
        await r.widget.iconsSettled()
        XCTAssertEqual(r.fetcher.requested, [], "https only")
        XCTAssertNil(r.widget.icon(for: try XCTUnwrap(r.widget.pins.sites.first)))
        XCTAssertEqual(SiteURL.letter(for: r.widget.pins.sites[0]), "I")
        r.widget.stop()
    }

    func testRedirectToAnotherHostRefusedAndRetriedOnceADay() async throws {
        let fetcher = FakeFetcher { _ in
            FaviconResponse(url: URL(string: "https://evil.com/favicon.ico")!, status: 200, contentType: "image/png",
                            data: LaunchWidgetTests.pngData)
        }
        let clock = Clock()
        let r = rig(fetcher: fetcher, clock: clock)
        r.widget.start(context: context())
        r.widget.pin(URL(string: "https://a.com")!)
        await r.widget.iconsSettled()
        XCTAssertEqual(fetcher.requested.map(\.host), ["a.com", "a.com"], "both candidates, only the pinned origin")
        XCTAssertNil(r.widget.icon(for: r.widget.pins.sites[0]), "redirected body refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("https_a.com_443.icon").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("https_a.com_443.failed").path))

        r.widget.refreshIcons()
        await r.widget.iconsSettled()
        XCTAssertEqual(fetcher.requested.count, 2, "not asked again within a day")

        clock.now = clock.now.addingTimeInterval(86_400 + 60)
        fetcher.respond = FakeFetcher.png
        r.widget.refreshIcons()
        await r.widget.iconsSettled()
        XCTAssertEqual(fetcher.requested.count, 3)
        XCTAssertNotNil(r.widget.icon(for: r.widget.pins.sites[0]))
        r.widget.stop()
    }

    func testTypeSizeAndDecodeCaps() async {
        let site = URL(string: "https://a.com/page")!
        let cases: [(String, @Sendable (URL) throws -> FaviconResponse)] = [
            ("html", { FaviconResponse(url: $0, status: 200, contentType: "text/html", data: LaunchWidgetTests.pngData) }),
            ("no type", { FaviconResponse(url: $0, status: 200, contentType: nil, data: LaunchWidgetTests.pngData) }),
            ("svg", { FaviconResponse(url: $0, status: 200, contentType: "image/svg+xml", data: Data("<svg/>".utf8)) }),
            ("too big", { FaviconResponse(url: $0, status: 200, contentType: "image/png",
                                          data: Data(count: FaviconPolicy.maxBytes + 1)) }),
            ("not an image", { FaviconResponse(url: $0, status: 200, contentType: "image/png", data: Data("hello".utf8)) }),
            ("404", { FaviconResponse(url: $0, status: 404, contentType: "image/png", data: LaunchWidgetTests.pngData) }),
            ("http downgrade", { _ in FaviconResponse(url: URL(string: "http://a.com/favicon.ico")!, status: 200,
                                                      contentType: "image/png", data: LaunchWidgetTests.pngData) }),
            ("error", { _ in throw URLError(.notConnectedToInternet) }),
        ]
        for (label, respond) in cases {
            let fetcher = FakeFetcher(respond: respond)
            let cache = FaviconCache(directory: tempDir(), fetcher: fetcher)
            let data = await cache.load(for: site)
            XCTAssertNil(data, label)
            XCTAssertEqual(fetcher.requested.count, 2, label)
            XCTAssertNil(cache.cached(for: site), label)
        }
        let ok = FaviconCache(directory: tempDir(), fetcher: FakeFetcher())
        let loaded = await ok.load(for: site)
        XCTAssertEqual(loaded, LaunchWidgetTests.pngData)
    }

    func testFreshCacheIsReusedAndExpiresAfter30Days() async throws {
        let d = defaults()
        let dir = tempDir()
        let clock = Clock()
        let first = rig(defaults: d, dir: dir, clock: clock)
        first.widget.start(context: context())
        first.widget.pin(URL(string: "https://a.com")!)
        first.widget.pin(URL(string: "https://a.com/other")!)
        await first.widget.iconsSettled()
        XCTAssertEqual(first.fetcher.requested.count, 1, "one fetch per origin")
        first.widget.stop()

        clock.now = clock.now.addingTimeInterval(29 * 86_400)
        let second = rig(defaults: d, dir: dir, clock: clock)
        second.widget.start(context: context())
        await second.widget.iconsSettled()
        XCTAssertEqual(second.fetcher.requested, [], "cached icon used")
        XCTAssertNotNil(second.widget.icon(for: second.widget.pins.sites[0]))
        second.widget.stop()

        clock.now = clock.now.addingTimeInterval(2 * 86_400)
        let third = rig(defaults: d, dir: dir, clock: clock)
        third.widget.start(context: context())
        await third.widget.iconsSettled()
        XCTAssertEqual(third.fetcher.requested, [URL(string: "https://a.com/favicon.ico")!], "expired: fetched again")
        third.widget.stop()
    }

    func testUnpinAndDisableDeleteIcons() async throws {
        let r = rig()
        r.widget.start(context: context())
        r.widget.pin(URL(string: "https://a.com")!)
        r.widget.pin(URL(string: "https://b.com")!)
        await r.widget.iconsSettled()
        let aFile = r.dir.appendingPathComponent("https_a.com_443.icon")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aFile.path))
        r.widget.remove(r.widget.pins.sites[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: aFile.path))
        XCTAssertEqual(r.widget.pins.sites.map(\.title), ["b.com"])
        XCTAssertEqual(LaunchPins.load(from: r.defaults).sites.map(\.title), ["b.com"], "saved")
        r.widget.stop()
        r.widget.disabled()
        XCTAssertFalse(FileManager.default.fileExists(atPath: r.dir.path))
        XCTAssertEqual(LaunchPins.load(from: r.defaults).sites.count, 1, "pins stay")
    }

    final class GatedFetcher: FaviconFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var _started = 0
        var started: Int { lock.withLock { _started } }
        func release() { lock.withLock { open = true } }

        /// Waits for `release()`, ignoring cancellation, then answers with a good icon.
        func fetch(_ url: URL) async throws -> FaviconResponse {
            lock.withLock { _started += 1 }
            while !lock.withLock({ open }) { try? await Task.sleep(for: .milliseconds(5)) }
            return try FakeFetcher.png(url)
        }
    }

    func testFetchFinishingAfterDisableWritesNothing() async throws {
        let fetcher = GatedFetcher()
        let dir = tempDir()
        let w = LaunchWidget(defaults: defaults(), faviconDirectory: dir, fetcher: { fetcher }, shortcuts: FakeShortcuts(),
                             tabs: FakeTabs(), open: { _ in true })
        w.start(context: context())
        w.pin(URL(string: "https://a.com")!)
        await waitFor { fetcher.started == 1 }
        w.stop()
        w.disabled()
        fetcher.release()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "nothing recreates favicons/ after disable")
    }

    func testClosedCacheNeverWritesEvenUncancelled() async throws {
        let fetcher = GatedFetcher()
        let dir = tempDir()
        let cache = FaviconCache(directory: dir, fetcher: fetcher)
        let load = Task.detached { await cache.load(for: URL(string: "https://a.com")!) }
        await waitFor { fetcher.started == 1 }
        cache.removeAll()
        fetcher.release()
        _ = await load.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        cache.reopen()
        let again = await cache.load(for: URL(string: "https://a.com")!)
        XCTAssertNotNil(again)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "reopened (started again): writes resume")
    }

    // MARK: - The real fetcher and redirect guard (no request is made)

    func testOriginFetcherRefusesNonHttpsBeforeAnyRequest() async {
        let f = OriginFaviconFetcher()
        for raw in ["http://a.com/favicon.ico", "file:///etc/hosts", "ftp://a.com/x"] {
            do {
                _ = try await f.fetch(URL(string: raw)!)
                XCTFail(raw)
            } catch {
                XCTAssertEqual(error as? FaviconError, .refused, raw)
            }
        }
    }

    func testRedirectGuardRefusesAnotherOrigin() async {
        let guardian = OriginFaviconFetcher.redirectGuard()
        let session = URLSession(configuration: EphemeralSession.configuration(requestTimeout: 1, resourceTimeout: 1))
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: URL(string: "https://a.com/favicon.ico")!))   // never resumed
        func decide(_ target: String) async -> URLRequest? {
            let response = HTTPURLResponse(url: URL(string: "https://a.com/favicon.ico")!, statusCode: 302,
                                           httpVersion: nil, headerFields: nil)!
            return await withCheckedContinuation { cont in
                guardian.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                    newRequest: URLRequest(url: URL(string: target)!)) { cont.resume(returning: $0) }
            }
        }
        let same = await decide("https://a.com/static/icon.ico")
        XCTAssertNotNil(same, "same origin followed")
        for other in ["https://cdn.a.com/f.ico", "https://evil.com/f.ico", "http://a.com/f.ico", "https://a.com:8443/f.ico"] {
            let r = await decide(other)
            XCTAssertNil(r, other)
        }
    }

    func testWeatherStillUsesItsHostGuard() {
        // The generalised guard keeps the weather rule (Open-Meteo hosts only).
        let g = RedirectGuard { _, target in OpenMeteo.isAllowed(target) }
        XCTAssertTrue(g.allows(URL(string: "https://a.com")!, URL(string: "https://api.open-meteo.com/v1/forecast")!))
        XCTAssertFalse(g.allows(URL(string: "https://api.open-meteo.com")!, URL(string: "https://evil.com/")!))
    }

    // MARK: - Add current tab

    func testAddCurrentTabOnlyFromTheButton() async throws {
        let r = rig()
        r.widget.start(context: context())
        await settle()
        XCTAssertEqual(r.tabs.calls, 0, "start never asks a browser")
        r.tabs.result = .url(URL(string: "https://b.com/page")!, .safari)
        r.widget.addCurrentTab()
        await waitFor { !r.widget.readingTab }
        XCTAssertEqual(r.tabs.calls, 1)
        XCTAssertEqual(r.widget.pins.sites.map(\.url), [URL(string: "https://b.com/page")!])
        XCTAssertEqual(r.widget.notice?.text, "Pinned b.com from Safari")
        await r.widget.iconsSettled()
        XCTAssertEqual(r.fetcher.requested, [URL(string: "https://b.com/favicon.ico")!])

        r.tabs.result = .noBrowser
        r.widget.addCurrentTab()
        await waitFor { !r.widget.readingTab }
        XCTAssertEqual(r.widget.notice?.text, "Open Safari, Chrome or Arc first.")
        r.tabs.result = .denied(.arc)
        r.widget.addCurrentTab()
        await waitFor { !r.widget.readingTab }
        XCTAssertTrue(r.widget.notice?.text.contains("Automation") == true)
        r.widget.stop()
    }

    func testScriptResultsAreValidatedBeforePinning() {
        typealias R = AppleScriptTabReader
        XCTAssertEqual(R.result(.value("https://x.com/a"), browser: .chrome), .url(URL(string: "https://x.com/a")!, .chrome))
        XCTAssertEqual(R.result(.value("javascript:alert(1)"), browser: .safari), .notWebPage(.safari))
        XCTAssertEqual(R.result(.value("file:///Users/me/a.pdf"), browser: .safari), .notWebPage(.safari))
        XCTAssertEqual(R.result(.value("about:blank"), browser: .arc), .notWebPage(.arc))
        XCTAssertEqual(R.result(.value("chrome://settings"), browser: .chrome), .notWebPage(.chrome))
        XCTAssertEqual(R.result(.value("example.com"), browser: .chrome), .notWebPage(.chrome), "no scheme added to script output")
        XCTAssertEqual(R.result(.value(""), browser: .safari), .noWindow(.safari))
        XCTAssertEqual(R.result(.failure(-1743), browser: .safari), .denied(.safari))
        XCTAssertEqual(R.result(.failure(-1712), browser: .safari), .timedOut(.safari))
        XCTAssertEqual(R.result(.failure(-600), browser: .chrome), .noBrowser)
    }

    // MARK: - Shortcuts

    func testShortcutsListOnlyWhenPickerOpensAndRunOnlyOnClick() async throws {
        let r = rig()
        r.widget.start(context: context())
        await settle()
        XCTAssertEqual(r.shortcuts.lists, 0)
        r.widget.openPicker()
        await waitFor { !r.widget.listing }
        XCTAssertEqual(r.shortcuts.lists, 1)
        XCTAssertEqual(r.widget.available, ["Log water", "Focus 25"])
        r.widget.pinShortcut("Log water")
        r.widget.closePicker()
        XCTAssertNil(r.widget.available)
        XCTAssertEqual(r.shortcuts.runs, [], "pinning never runs")

        r.widget.run(r.widget.pins.shortcuts[0])
        await waitFor { r.widget.runningShortcut == nil }
        XCTAssertEqual(r.shortcuts.runs, ["Log water"])
        XCTAssertEqual(r.widget.notice?.text, "“Log water” done")
        XCTAssertNotNil(r.widget.peekView(id: LaunchWidget.resultPeekID))

        r.shortcuts.outcome = .failed(2)
        r.widget.run(r.widget.pins.shortcuts[0])
        await waitFor { r.widget.runningShortcut == nil }
        XCTAssertEqual(r.widget.notice?.text, "“Log water” failed (exit 2)")
        XCTAssertEqual(r.widget.notice?.isError, true)

        r.shortcuts.hang = true
        r.widget.run(r.widget.pins.shortcuts[0])
        await waitFor { r.shortcuts.runs.count == 3 }
        r.widget.run(r.widget.pins.shortcuts[0])
        XCTAssertEqual(r.shortcuts.runs.count, 3, "one at a time")
        r.widget.cancelShortcut()
        await waitFor { r.widget.runningShortcut == nil }
        XCTAssertEqual(r.widget.notice?.text, "“Log water” cancelled")
        r.widget.stop()
    }

    // MARK: - ShortcutsRunner over ProcessRunner (a stand-in script, never /usr/bin/shortcuts)

    private func script(_ body: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnsc\(UUID().uuidString)")
        dirs.append(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("shortcuts")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testRunnerPassesTheNameAsOneArgument() async throws {
        let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnargs\(UUID().uuidString)")
        dirs.append(out)
        let bin = try script("for a in \"$@\"; do printf '[%s]\\n' \"$a\" >> '\(out.path)'; done; exit 0")
        let runner = ShortcutsRunner(executableURL: bin)
        let outcome = await runner.run("$(touch /tmp/pwned) ; --help")
        XCTAssertEqual(outcome, .done)
        let args = try String(contentsOf: out, encoding: .utf8)
        XCTAssertEqual(args, "[run]\n[--]\n[$(touch /tmp/pwned) ; --help]\n")
    }

    func testRunnerReportsExitCodeAndList() async throws {
        let bin = try script("if [ \"$1\" = list ]; then printf 'A\\nB\\n'; exit 0; fi; exit 4")
        let runner = ShortcutsRunner(executableURL: bin)
        let names = await runner.list()
        XCTAssertEqual(names, ["A", "B"])
        let outcome = await runner.run("A")
        XCTAssertEqual(outcome, .failed(4))
        let missing = await ShortcutsRunner(executableURL: URL(fileURLWithPath: "/nonexistent/shortcuts")).run("A")
        if case .unavailable = missing {} else { XCTFail("\(missing)") }
        let none = await ShortcutsRunner(executableURL: URL(fileURLWithPath: "/nonexistent/shortcuts")).list()
        XCTAssertNil(none)
    }

    func testRunnerStopsAHangingShortcut() async throws {
        let bin = try script("exec sleep 30")
        let runner = ShortcutsRunner(executableURL: bin, runTimeout: .seconds(1))
        let start = Date()
        let outcome = await runner.run("Slow")
        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }

    func testRunnerCancelStopsTheProcess() async throws {
        let bin = try script("trap '' TERM; while :; do sleep 0.2; done")   // ignores SIGTERM: SIGKILL follows
        let runner = ShortcutsRunner(executableURL: bin)
        let start = Date()
        let task = Task { await runner.run("Slow") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testGrandchildHoldingThePipesDoesNotHoldTheCaller() async throws {
        let bin = try script("sleep 4 & echo started; exit 3")
        let start = Date()
        let r = await ProcessRunner(executableURL: bin).run([], timeout: .seconds(10))
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.stdout, "started\n")
        XCTAssertTrue(r.truncated, "the grandchild still held the pipe")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3.5)
    }

    func testFullOutputIsReadToEOFAndNotTruncated() async throws {
        let bin = try script("head -c 600000 /dev/zero; head -c 300000 /dev/zero >&2; exit 0")
        for _ in 0..<5 {
            let r = await ProcessRunner(executableURL: bin).run([], timeout: .seconds(10))
            XCTAssertEqual(r.status, 0)
            XCTAssertFalse(r.truncated)
            XCTAssertEqual(r.stdout.utf8.count, 600_000)
            XCTAssertEqual(r.stderr.utf8.count, 300_000)
        }
    }

    func testCoreRunnerTreatsTruncatedOutputAsAnError() async throws {
        let bin = try script("sleep 4 & echo '{\"ok\":true}'; exit 0")
        let r = await CoreRunner(binaryURL: bin).run(["hooks", "status"])
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.status, CoreRunner.truncatedStatus, "never a silent status 0 with partial output")
        XCTAssertTrue(r.combined.contains("output incomplete"))
    }

    func testCoreRunnerIgnoresTaskCancellation() async throws {
        let bin = try script("sleep 1; echo done")
        let task = Task { await CoreRunner(binaryURL: bin).run(["hooks", "status"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        let r = await task.value
        XCTAssertEqual(r.status, 0, "a view's .task ending must not SIGTERM the command")
        XCTAssertEqual(r.stdout, "done\n")
        XCTAssertFalse(r.cancelled)
    }

    func testProcessRunnerCapsOutput() async throws {
        let bin = try script("head -c 3000000 /dev/zero")
        let r = await ProcessRunner(executableURL: bin).run([], timeout: .seconds(10))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.stdout.utf8.count, ProcessRunner.maxOutput)
    }

    // MARK: - Registry

    func testRegisteredOnByDefault() {
        let registry = WidgetRegistry(defaults: defaults())
        registry.register(LaunchWidget.inert())
        XCTAssertTrue(registry.isEnabled(LaunchWidget.widgetID))
    }
}
