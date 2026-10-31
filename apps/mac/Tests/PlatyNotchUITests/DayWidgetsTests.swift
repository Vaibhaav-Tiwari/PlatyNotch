import CoreLocation
import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

/// Records every URL asked for and answers from a table. Never touches the network.
private final class FakeFetcher: WeatherFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [URL] = []
    private let answer: @Sendable (URL) throws -> Data

    init(answer: @escaping @Sendable (URL) throws -> Data) { self.answer = answer }

    var urls: [URL] { lock.withLock { asked } }

    func data(from url: URL) async throws -> Data {
        lock.withLock { asked.append(url) }
        return try answer(url)
    }
}

/// macOS Location stand-in: counts permission requests, answers with a fixed place.
@MainActor
private final class FakeLocation: LocationProviding {
    var auth: LocationAuth
    var onAuthChange: (() -> Void)?
    /// `fix()` throws while set (no Wi-Fi, `kCLErrorLocationUnknown`).
    var failFix = false
    private let grant: LocationAuth
    private(set) var requests = 0
    private(set) var fixes = 0

    init(auth: LocationAuth, grant: LocationAuth = .granted) {
        self.auth = auth
        self.grant = grant
    }

    func requestAccess() async -> LocationAuth {
        requests += 1
        auth = grant
        return auth
    }

    func fix() async throws -> LocationFix {
        fixes += 1
        if failFix { throw LocationError.failed("unknown") }
        return LocationFix(latitude: 12.97, longitude: 77.59, name: "Bengaluru")
    }
}

@MainActor
final class DayWidgetsTests: DefaultsTestCase {



    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func context(_ registry: WidgetRegistry? = nil, surfaces: PanelSurfaces? = nil) -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnday\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(),
                             surfaces: surfaces, openPanel: { _ in })
    }

    nonisolated private static let fixture: Data = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../PlatyNotchKitTests/Fixtures/open-meteo.json").standardized
        return (try? Data(contentsOf: url)) ?? Data()
    }()

    nonisolated private static let geocoding = Data(#"{"results":[{"id":1,"name":"Lisbon","latitude":38.71667,"longitude":-9.13333,"country":"Portugal"}]}"#.utf8)

    private static let lisbon = GeoPlace(id: 1, name: "Lisbon", country: "Portugal", latitude: 38.71667, longitude: -9.13333)

    private func okFetcher() -> FakeFetcher {
        FakeFetcher { url in url.host == OpenMeteo.geocodingHost ? DayWidgetsTests.geocoding : DayWidgetsTests.fixture }
    }

    // MARK: - Weather

    /// Off by default; a widget that never started never asks for anything.
    func testWeatherOffByDefaultAndSilentUntilStarted() async {
        let fetcher = okFetcher()
        let d = defaults()
        let registry = WidgetRegistry(defaults: d)
        let weather = WeatherWidget(defaults: d, fetcher: { fetcher }, watchSystem: false)
        registry.register(weather)
        registry.start(context: context())
        XCTAssertFalse(registry.isEnabled(WeatherWidget.widgetID))
        XCTAssertFalse(weather.running)
        weather.query = "Lisbon"
        weather.search()
        await weather.fetch()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fetcher.urls, [], "nothing is sent while the widget is off")
    }

    func testWeatherFetchesOnlyTheForecastHostWithCoordinates() async throws {
        let fetcher = okFetcher()
        let d = defaults()
        let weather = WeatherWidget(defaults: d, fetcher: { fetcher }, watchSystem: false)
        weather.start(context: context())
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fetcher.urls, [], "no city yet: no request")

        weather.query = "Lisbon"
        weather.search()
        await waitUntil { !weather.results.isEmpty }
        XCTAssertEqual(weather.results, [Self.lisbon])
        let search = try XCTUnwrap(fetcher.urls.first)
        XCTAssertEqual(search.host, OpenMeteo.geocodingHost)
        XCTAssertTrue(search.absoluteString.contains("name=Lisbon"))

        weather.choose(weather.results[0])
        await waitUntil { weather.weather != nil }
        XCTAssertEqual(fetcher.urls.count, 2)
        let forecast = fetcher.urls[1]
        XCTAssertEqual(forecast.host, OpenMeteo.forecastHost)
        XCTAssertFalse(forecast.absoluteString.localizedCaseInsensitiveContains("lisbon"), "the city name goes only to the geocoder")
        XCTAssertTrue(forecast.absoluteString.contains("latitude=38.72"))
        XCTAssertTrue(fetcher.urls.allSatisfy(OpenMeteo.isAllowed))
        XCTAssertEqual(weather.weather?.code, 3)
        XCTAssertEqual(weather.liveActivities.first?.priority, WeatherWidget.livePriority)
        XCTAssertTrue(weather.liveActivities.first?.isAmbient ?? false)
        // The place is remembered.
        XCTAssertEqual(WeatherWidget(defaults: d, fetcher: { fetcher }, watchSystem: false).place, Self.lisbon)
        weather.stop()
    }

    func testWeatherBacksOffAndKeepsStaleData() async {
        final class Flag: @unchecked Sendable { var fail = false }
        let flag = Flag()
        let fetcher = FakeFetcher { _ in
            if flag.fail { throw URLError(.timedOut) }
            return DayWidgetsTests.fixture
        }
        let d = defaults()
        let weather = WeatherWidget(defaults: d, fetcher: { fetcher }, watchSystem: false)
        weather.start(context: context())
        weather.choose(Self.lisbon)
        await waitUntil { weather.weather != nil }
        XCTAssertEqual(fetcher.urls.count, 1)

        flag.fail = true
        await weather.fetch()
        XCTAssertEqual(weather.failures, 1)
        XCTAssertNotNil(weather.lastError)
        XCTAssertNotNil(weather.weather, "the last data stays, with its age")
        XCTAssertNotNil(weather.ageNote(at: Date()))
        // The retry waits (1 min): nothing more is sent right away.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fetcher.urls.count, 2)
        weather.stop()
    }

    func testWeatherPausesWhileAsleepOrOffline() async {
        let fetcher = okFetcher()
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false)
        weather.start(context: context())
        weather.setAsleep(true)
        weather.choose(Self.lisbon)
        await weather.fetch()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(fetcher.urls, [], "asleep: no request")
        weather.setAsleep(false)
        weather.setOnline(false)
        await weather.fetch()
        XCTAssertEqual(fetcher.urls, [], "offline: no request")
        XCTAssertTrue(weather.paused)
        weather.stop()
        await weather.fetch()
        XCTAssertEqual(fetcher.urls, [], "stopped: no request")
    }

    func testWeatherDisableForgetsForecast() async {
        let fetcher = okFetcher()
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false)
        weather.start(context: context())
        weather.choose(Self.lisbon)
        await waitUntil { weather.weather != nil }
        weather.stop()
        weather.disabled()
        XCTAssertNil(weather.weather)
        XCTAssertEqual(weather.liveActivities, [])
        XCTAssertEqual(weather.place, Self.lisbon, "the chosen city stays")
    }

    func testRefusingFetcherAndClientGuard() async {
        do {
            _ = try await RefusingFetcher().data(from: URL(string: "https://api.open-meteo.com/")!)
            XCTFail("must refuse")
        } catch {
            XCTAssertEqual(error as? WeatherError, .refusedHost)
        }
        let fetcher = okFetcher()
        let places = try? await WeatherClient(fetcher: fetcher).places(named: "x")
        XCTAssertEqual(places, [], "too short: nothing sent")
        XCTAssertEqual(fetcher.urls, [])
    }

    // MARK: - Weather location (Island spec 5)

    /// Opening (starting) the widget never asks for Location; it waits for a click.
    func testOpeningNeverRequestsLocation() async {
        let fetcher = okFetcher()
        let fake = FakeLocation(auth: .notDetermined)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: fake)
        weather.start(context: context())
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fake.requests, 0)
        XCTAssertEqual(fake.fixes, 0)
        XCTAssertEqual(weather.source, .needsPermission)
        XCTAssertEqual(fetcher.urls, [])
        weather.stop()
    }

    /// "Use my location" asks once, then fetches the forecast at the fix.
    func testUseMyLocationAsksOnceThenFetches() async {
        let fetcher = okFetcher()
        let fake = FakeLocation(auth: .notDetermined)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: fake)
        weather.start(context: context())
        await weather.useMyLocation()
        await waitUntil { weather.weather != nil }
        XCTAssertEqual(fake.requests, 1)
        XCTAssertEqual(fetcher.urls, [OpenMeteo.forecastURL(latitude: 12.97, longitude: 77.59)])
        XCTAssertEqual(weather.placeName, "Bengaluru")
        XCTAssertEqual(WeatherLocation.load(from: defaults()), .automatic)
        // Already granted: a second click asks nothing.
        await weather.useMyLocation()
        XCTAssertEqual(fake.requests, 1)
        weather.stop()
    }

    /// Denied: the saved city, and no second prompt.
    func testDeniedUsesTheSavedCity() async {
        let fetcher = okFetcher()
        let fake = FakeLocation(auth: .denied, grant: .denied)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: fake)
        weather.start(context: context())
        weather.choose(Self.lisbon)
        WeatherLocation.automatic.save(to: defaults())
        XCTAssertEqual(weather.source, .place(latitude: Self.lisbon.latitude, longitude: Self.lisbon.longitude, name: "Lisbon"))
        XCTAssertEqual(fake.requests, 0)
        weather.stop()
    }

    // MARK: - Meetings

    private func meetingWidget(now: Date, meetings: [CalendarMeeting], focusUntil: Date? = nil,
                               policy: NotificationPolicy = NotificationPolicy())
        -> (MeetingWidget, WidgetRegistry, PanelSurfaces) {
        let d = defaults()
        if let focusUntil { d.set(focusUntil, forKey: FocusModel.untilKey) }
        let calendar = CalendarService(eventKit: false)
        calendar.setForTesting(access: .granted, meetings: meetings)
        let widget = MeetingWidget(calendar: calendar, defaults: d, clock: { now })
        let registry = WidgetRegistry(defaults: d)
        let surfaces = PanelSurfaces(registry: registry)
        // The app's focus signal for Settings › Notifications (a running focus session).
        let focusActive: Bool = focusUntil.map { $0 > now } ?? false
        surfaces.focusActive = { focusActive }
        surfaces.notificationPolicy = policy
        registry.register(widget)
        registry.start(context: context(registry, surfaces: surfaces))
        return (widget, registry, surfaces)
    }

    func testMeetingReminderPeeksAndCountdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(4 * 60 + 30)
        let m = CalendarMeeting(id: "standup", title: "Standup", start: start, end: start.addingTimeInterval(900),
                                joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        let (widget, registry, _) = meetingWidget(now: now, meetings: [m])
        XCTAssertEqual(widget.reminder, MeetingWidget.Reminder(meeting: m, minutes: 5), "4.5 min ahead: the 5-minute reminder")
        XCTAssertNotNil(widget.peekView(id: MeetingWidget.reminderPeekID))
        let live = widget.liveActivities
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.priority, LivePriority.meetingSoon)
        XCTAssertEqual(live.first?.countdownTo, start)
        guard case .ring(let progress)? = live.first?.glyph else { return XCTFail("countdown ring") }
        XCTAssertEqual(progress, 0.55, accuracy: 1e-9)
        XCTAssertFalse(widget.inMeeting)
        registry.stopAll()
        XCTAssertNil(widget.reminder)
    }

    func testMeetingRemindersQuietDuringFocus() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(60)
        let m = CalendarMeeting(id: "1on1", title: "1:1", start: start, end: start.addingTimeInterval(900))
        let (widget, registry, _) = meetingWidget(now: now, meetings: [m], focusUntil: now.addingTimeInterval(600))
        XCTAssertNil(widget.reminder, "Meeting starting is quiet during focus sessions by default")
        XCTAssertEqual(widget.liveActivities.count, 1, "the pill countdown still shows")
        registry.stopAll()
        // Settings › Notifications decides: not quiet, it peeks during a focus session.
        var policy = NotificationPolicy()
        policy[.meetingStarting] = NotificationRule(showInPill: true, canOpen: true, quietDuringFocus: false)
        let (loud, loudRegistry, _) = meetingWidget(now: now, meetings: [m], focusUntil: now.addingTimeInterval(600),
                                                     policy: policy)
        XCTAssertEqual(loud.reminder, MeetingWidget.Reminder(meeting: m, minutes: 1))
        loudRegistry.stopAll()
    }

    func testInMeetingAndNothingSoon() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let m = CalendarMeeting(id: "now", title: "Review", start: now.addingTimeInterval(-600), end: now.addingTimeInterval(600))
        let later = CalendarMeeting(id: "later", title: "Later", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400))
        let (widget, registry, _) = meetingWidget(now: now, meetings: [m, later])
        XCTAssertTrue(widget.inMeeting)
        XCTAssertEqual(widget.current?.id, "now")
        XCTAssertNil(widget.reminder)
        XCTAssertEqual(widget.liveActivities, [], "nothing within 10 minutes")
        registry.stopAll()
        XCTAssertFalse(widget.calendar.watching, "a stopped widget observes nothing")
        XCTAssertEqual(widget.calendar.meetings, [])
    }

    /// The calendar is never asked for on start or on tile show (C25): an inert service
    /// stays `.unavailable` and a fresh real one only reads its status.
    func testMeetingStartNeverRequestsAccess() {
        let calendar = CalendarService(eventKit: false)
        let widget = MeetingWidget(calendar: calendar)
        widget.start(context: context())
        _ = widget.tileView()
        XCTAssertEqual(calendar.access, .unavailable)
        widget.stop()
    }

    /// Final review C13: without calendar access there is no periodic wake; a grant (the
    /// access status changing) starts the reads and the timer.
    func testMeetingNoWakesWithoutAccess() async {
        let calendar = CalendarService(eventKit: false)
        let widget = MeetingWidget(calendar: calendar)
        widget.start(context: context())
        XCTAssertFalse(widget.hasWakeScheduled, "no 30 s timer while access is missing")
        widget.tick()
        XCTAssertFalse(widget.hasWakeScheduled)
        calendar.setForTesting(access: .granted, meetings: [])
        for _ in 0..<20 where !widget.hasWakeScheduled { await Task.yield() }
        XCTAssertTrue(widget.hasWakeScheduled, "the grant is picked up without polling")
        widget.stop()
        XCTAssertFalse(widget.hasWakeScheduled)
    }

    /// Round 2: turning the widget off and on quickly leaves one access observation, not two.
    func testMeetingAccessObservationEndsWithStop() async {
        let calendar = CalendarService(eventKit: false)
        let widget = MeetingWidget(calendar: calendar)
        let ctx = context()
        widget.start(context: ctx)
        widget.stop()
        widget.start(context: ctx)
        let before = widget.ticks
        calendar.setForTesting(access: .granted, meetings: [])
        _ = await eventually { widget.ticks > before }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(widget.ticks, before + 1, "the earlier run's observation chain stopped")
        widget.stop()
    }

    // MARK: - Reminders

    func testRemindersWidgetOffByDefaultAndInert() {
        let widget = RemindersWidget.inert()
        XCTAssertFalse(widget.defaultEnabled)
        widget.draft = "call Priya at 5pm"
        widget.addDraft()   // not running: nothing happens
        XCTAssertEqual(widget.draft, "call Priya at 5pm")
        widget.start(context: context())
        XCTAssertEqual(widget.reminders.access, .unavailable)
        widget.addDraft()   // no access: nothing is written
        XCTAssertEqual(widget.draft, "call Priya at 5pm")
        widget.stop()
    }

    func testRemindersTileOrder() {
        let widget = RemindersWidget.inert()
        let now = Calendar.autoupdatingCurrent.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        widget.reminders.setForTesting(access: .granted, items: [
            ReminderItem(id: "a", title: "Later", due: now.addingTimeInterval(60), hasTime: true),
            ReminderItem(id: "b", title: "Late", due: now.addingTimeInterval(-60), hasTime: true),
            ReminderItem(id: "c", title: "Someday", due: nil, hasTime: false),
        ])
        XCTAssertEqual(widget.shown(at: now).map(\.id), ["b", "a"])
        XCTAssertTrue(widget.isOverdue(widget.shown(at: now)[0], at: now))
    }
}

/// Phase A review fixes: Location from the Privacy row, failed fixes and fetches, the
/// tool's copy and the geocoder's rounding.
@MainActor
final class WeatherRecoveryTests: DefaultsTestCase {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func context() -> WidgetContext {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnwx\(UUID().uuidString)")
        return WidgetContext(store: AppStore(), client: CoreClient(socketPath: "/nonexistent"),
                             config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                             events: CoreEventHub(), defaults: defaults(), notify: NoopNotifier(), surfaces: nil,
                             openPanel: { _ in })
    }

    nonisolated private static let forecast: Data = {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../PlatyNotchKitTests/Fixtures/forecast-daily.json").standardized
        return (try? Data(contentsOf: url)) ?? Data()
    }()

    private final class Fetcher: WeatherFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var failing: Bool
        init(failing: Bool) { self.failing = failing }
        var asked: Int { lock.withLock { count } }
        func setFailing(_ f: Bool) { lock.withLock { failing = f } }
        func data(from url: URL) async throws -> Data {
            let fail = lock.withLock { count += 1; return failing }
            if fail { throw URLError(.cannotConnectToHost) }
            return WeatherRecoveryTests.forecast
        }
    }

    private final class Location: LocationProviding {
        var auth: LocationAuth
        var onAuthChange: (() -> Void)?
        var failFix = false
        private(set) var requests = 0
        init(auth: LocationAuth) { self.auth = auth }
        func requestAccess() async -> LocationAuth { requests += 1; auth = .granted; return auth }
        func fix() async throws -> LocationFix {
            if failFix { throw LocationError.failed("unknown") }
            return LocationFix(latitude: 12.97, longitude: 77.59, name: "Bengaluru")
        }
    }

    private let lisbon = GeoPlace(id: 1, name: "Lisbon", latitude: 38.72, longitude: -9.13)

    /// C1: Allow on the Privacy (or onboarding) row goes through the widget and loads the sky.
    func testPrivacyAllowLoadsTheSky() async {
        let fetcher = Fetcher(failing: false)
        let loc = Location(auth: .notDetermined)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: loc)
        weather.start(context: context())
        let permissions = Permissions(calendar: CalendarService(eventKit: false), reminders: RemindersService(eventKit: false))
        permissions.weatherLocation = { await weather.useMyLocation() }
        await permissions.requestLocation(defaults: defaults())
        await waitUntil { weather.weather != nil }
        XCTAssertEqual(loc.requests, 1)
        XCTAssertNotNil(weather.weather, "the sky loads straight away")
        XCTAssertEqual(SkyContent.of(weather, now: Date())?.texts.dropFirst().first, "Sunny · Bengaluru")
        XCTAssertTrue(weather.usesMyLocation)
        weather.stop()
    }

    /// C1: `.automatic` written from outside, then access granted in System Settings: a fetch.
    func testExternalChoiceAndGrantFetch() async {
        let fetcher = Fetcher(failing: false)
        let loc = Location(auth: .notDetermined)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: loc)
        weather.start(context: context())
        WeatherLocation.automatic.save(to: defaults())
        loc.auth = .granted
        loc.onAuthChange?()
        await waitUntil { weather.weather != nil }
        XCTAssertNotNil(weather.weather)
        XCTAssertEqual(loc.requests, 0, "nothing asked")
        weather.stop()
    }

    /// I1: a failed fix with no city never shows "Loading…" forever: it says so, retries, recovers.
    func testFailedFixShowsErrorAndRetries() async {
        let fetcher = Fetcher(failing: false)
        let loc = Location(auth: .granted)
        loc.failFix = true
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: loc)
        weather.start(context: context())
        await weather.useMyLocation()
        XCTAssertFalse(weather.locating)
        XCTAssertEqual(weather.failures, 1)
        XCTAssertEqual(SkyContent.of(weather, now: Date()), .failed(title: "Can't find your location", retry: true))
        XCTAssertEqual(SkyContent.of(weather, now: Date())?.texts, ["Can't find your location", "Try again", "Add a city"])
        loc.failFix = false
        weather.retryNow()
        await waitUntil { weather.weather != nil }
        XCTAssertNotNil(weather.weather)
        weather.stop()
    }

    /// I2: a failing first fetch, and offline, show a real state instead of "Loading…".
    func testFailedFetchAndOfflineStates() async {
        let fetcher = Fetcher(failing: true)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { fetcher }, watchSystem: false, location: Location(auth: .denied))
        weather.start(context: context())
        weather.choose(lisbon)
        await waitUntil { weather.failures > 0 }
        XCTAssertEqual(SkyContent.of(weather, now: Date()), .failed(title: "Can't get weather", retry: true))
        weather.setOnline(false)
        XCTAssertEqual(SkyContent.of(weather, now: Date()), .failed(title: "Offline", retry: false))
        weather.setOnline(true)
        // Recovers, then a later failure keeps the data and shows its age.
        fetcher.setFailing(false)
        weather.retryNow()
        await waitUntil { weather.weather != nil }
        fetcher.setFailing(true)
        await weather.fetch()
        guard case .reading(_, _, _, _, let detail)? = SkyContent.of(weather, now: Date().addingTimeInterval(2 * 3600)) else {
            return XCTFail("stale data still shows")
        }
        XCTAssertTrue(detail?.contains("updated 2 h ago") ?? false, "\(detail ?? "nil")")
        weather.stop()
    }

    /// I4: the place name follows the real source; the copy never claims no location access.
    func testPlaceNameAndCopyFollowTheSource() async {
        defaults().set(try! JSONEncoder().encode(lisbon), forKey: WeatherWidget.placeKey)
        let loc = Location(auth: .granted)
        let weather = WeatherWidget(defaults: defaults(), fetcher: { Fetcher(failing: false) }, watchSystem: false,
                                    location: loc)
        weather.start(context: context())
        XCTAssertEqual(weather.placeName, "Lisbon")
        await weather.useMyLocation()
        XCTAssertEqual(weather.placeName, "Bengaluru", "the reading at your location is named for it")
        for source in [WeatherSource.needsPermission, .needsCity] {
            let text = WeatherWidget.emptyText(source)
            XCTAssertNotNil(text)
            XCTAssertFalse(text!.detail.contains("No location access"), "\(source)")
        }
        XCTAssertNil(WeatherWidget.emptyText(.place(latitude: 1, longitude: 2, name: nil)))
        weather.stop()
    }

    /// I3: the reverse geocoder gets the rounded position.
    func testGeocoderGetsTheRoundedPosition() {
        let r = SystemLocation.rounded(.init(latitude: 12.971_598_7, longitude: 77.594_562_1))
        XCTAssertEqual(r.coordinate.latitude, 12.97, accuracy: 1e-9)
        XCTAssertEqual(r.coordinate.longitude, 77.59, accuracy: 1e-9)
    }
}
