import AppKit
import Network
import Observation
import PlatyNotchKit
import SwiftUI

/// The weather where you are (macOS Location, after "Use my location") or for a city typed
/// in Settings, from Open-Meteo: temperature, conditions, today's high and low and when
/// rain is next likely (≥ 50%), in °C or °F.
///
/// Privacy: does nothing until enabled. It talks only to `geocoding-api.open-meteo.com`
/// (the typed city name, from Settings' Search button) and `api.open-meteo.com` (the
/// place's coordinates, rounded to ~1 km), over https, through `OpenMeteoFetcher`
/// (ephemeral session, no cookies or cache, redirects to other hosts refused). Location is
/// asked only from `useMyLocation()` (a click); starting or opening never prompts. One fix
/// per refresh; denied or revoked falls back to the saved city (`WeatherPlace.source`).
///
/// Refresh: every 30 minutes while enabled; paused while the Mac sleeps or is offline
/// (then the tile shows the last data with its age); failures back off 1, 2, 4… minutes
/// up to 30 (`WeatherRefresh`).
@MainActor @Observable
final class WeatherWidget: NotchWidget {
    static let widgetID = "weather"
    static let placeKey = "weather.place"
    static let unitKey = "weather.unit"
    /// Below ambient (shelf): weather shows in the pill only when nothing else is live.
    static let livePriority = 5

    let id = WeatherWidget.widgetID
    let title = "Weather"
    let systemImage = "cloud.sun"
    let defaultEnabled = false

    private(set) var place: GeoPlace?
    var unit: TemperatureUnit {
        didSet { if persist { defaults.set(unit.rawValue, forKey: Self.unitKey) } }
    }
    private(set) var weather: WeatherNow?
    private(set) var fetchedAt: Date?
    private(set) var failures = 0
    private(set) var lastError: String?
    private(set) var asleep = false
    private(set) var offline = false
    private(set) var loading = false

    /// Settings' city search.
    var query = ""
    private(set) var results: [GeoPlace] = []
    private(set) var searching = false
    private(set) var searchMessage: String?

    /// Renders only (a widget that does not persist): a fixed place and reading, so the
    /// header says "14° Clear" without a network call.
    func showForRendering(place: GeoPlace, weather: WeatherNow) {
        guard !persist else { return }
        self.place = place
        self.weather = weather
        renderLocation = .city(place)
        locationRevision += 1
    }

    /// Renders only: the sky's empty and loading states.
    func showEmptyForRendering() {
        guard !persist else { return }
        place = nil
        weather = nil
        renderLocation = nil
        locationRevision += 1
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let makeFetcher: () -> WeatherFetching
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let watchSystem: Bool
    @ObservationIgnored private let location: LocationProviding
    /// The last Location fix (automatic only); the place name it came with.
    private(set) var fix: LocationFix?
    /// Bumped when the chosen location changes, so `source` is re-read.
    private var locationRevision = 0
    /// Created when the widget first starts (no session exists while it was never on).
    @ObservationIgnored private var client: WeatherClient?
    @ObservationIgnored private(set) var running = false
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var monitor: NWPathMonitor?

    /// `watchSystem: false` (tests) skips the sleep/wake observers and the network monitor.
    init(defaults: UserDefaults = .standard, persist: Bool = true, fetcher: @escaping () -> WeatherFetching = { OpenMeteoFetcher() },
         clock: @escaping () -> Date = Date.init, watchSystem: Bool = true, location: LocationProviding? = nil) {
        self.defaults = defaults
        self.persist = persist
        makeFetcher = fetcher
        self.clock = clock
        self.watchSystem = watchSystem
        self.location = location ?? (persist ? SystemLocation() : NoLocation())
        place = defaults.data(forKey: Self.placeKey).flatMap { try? JSONDecoder().decode(GeoPlace.self, from: $0) }
        unit = defaults.string(forKey: Self.unitKey).flatMap(TemperatureUnit.init(rawValue:)) ?? .forLocale(.current)
    }

    /// A copy that never touches the network or Location, or saves anything (smoke runs).
    static func inert() -> WeatherWidget {
        WeatherWidget(persist: false, fetcher: { RefusingFetcher() }, watchSystem: false, location: NoLocation())
    }

    // MARK: - Location

    /// The saved choice (nil: never chosen).
    var chosenLocation: WeatherLocation? {
        _ = locationRevision
        return persist ? WeatherLocation.load(from: defaults) : renderLocation
    }

    @ObservationIgnored private var renderLocation: WeatherLocation?

    /// Where the forecast comes from, or which empty state the sky shows. Reads Location's
    /// state only while the choice is automatic, and never asks.
    var source: WeatherSource {
        let chosen = chosenLocation
        let auth: LocationAuth = chosen == .automatic ? location.auth : .notDetermined
        return WeatherPlace.source(location: chosen, auth: auth, fix: fix, savedCity: place)
    }

    /// The place's name for the sky ("Bengaluru"), when known.
    var placeName: String? {
        if case .place(_, _, let name) = source { return name }
        return nil
    }

    /// Whether "Use my location" is the choice (Settings' switch).
    var usesMyLocation: Bool { chosenLocation == .automatic }

    /// "Use my location" (Settings or the sky's empty state): the only path that may show
    /// the macOS prompt. Denied: the saved city stays, and nothing asks again.
    func useMyLocation() async {
        setChosen(.automatic)
        var auth = location.auth
        if auth == .notDetermined { auth = await location.requestAccess() }
        locationRevision += 1
        guard auth == .granted else { return }
        lastAttempt = nil
        failures = 0
        await refreshNow()
    }

    /// Settings' switch turned off: back to the saved city (or "Add a city").
    func useCity() {
        if let place { setChosen(.city(place)) } else { setChosen(nil) }
        fix = nil
        weather = nil
        fetchedAt = nil
        schedule()
    }

    private func setChosen(_ l: WeatherLocation?) {
        if persist {
            if let l { l.save(to: defaults) } else { defaults.removeObject(forKey: WeatherLocation.key) }
        } else {
            renderLocation = l
        }
        locationRevision += 1
    }

    /// Fetch now (after the location changed), then keep the usual schedule.
    private func refreshNow() async {
        task?.cancel()
        task = nil
        await fetch()
    }

    /// Whether a fetch can run: a place, or Location granted and automatic (a fix comes first).
    private var canFetch: Bool {
        if case .place = source { return true }
        return chosenLocation == .automatic && location.auth == .granted
    }

    var paused: Bool { asleep || offline }

    var liveActivities: [LiveActivity] {
        guard hasContent, let weather else { return [] }
        let d = WeatherCode.describe(weather.code, isDay: weather.isDay)
        let temp = WeatherFormat.temperature(weather.temperatureC, unit: unit)
        return [LiveActivity(id: "weather", widgetID: id, priority: Self.livePriority, glyph: .symbol(d.symbol),
                             trailing: temp, accessibilityLabel: "\(temp), \(d.text)")]
    }

    var kind: WidgetKind { [.glance, .tool] }

    /// A forecast is loaded for a place.
    var hasContent: Bool {
        guard weather != nil, case .place = source else { return false }
        return true
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        running = true
        if client == nil { client = WeatherClient(fetcher: makeFetcher()) }
        if watchSystem { watchSleep(); watchNetwork() }
        schedule()
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
        searchTask?.cancel()
        searchTask = nil
        searching = false
        loading = false
        let ws = NSWorkspace.shared.notificationCenter
        for o in observers { ws.removeObserver(o) }
        observers = []
        monitor?.cancel()
        monitor = nil
        asleep = false
        offline = false
    }

    /// Turned off: forget the forecast and the search (the chosen city stays).
    func disabled() {
        weather = nil
        fetchedAt = nil
        failures = 0
        lastAttempt = nil
        lastError = nil
        results = []
        query = ""
        searchMessage = nil
    }

    // MARK: - Refresh

    /// Sleeps until the next fetch is due (now when never fetched), unless paused.
    private func schedule(resuming: Bool = false) {
        task?.cancel()
        task = nil
        guard running, !paused, canFetch else { return }
        var delay = WeatherRefresh.delay(lastSuccess: fetchedAt, lastAttempt: lastAttempt, failures: failures, now: clock())
        if resuming { delay = max(delay, WeatherRefresh.resumeDelay) }
        task = Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            await self?.fetch()
        }
    }

    /// One forecast request, then the next one is scheduled (backing off after failures).
    func fetch() async {
        guard running, !paused, canFetch, let client else { return }
        lastAttempt = clock()
        loading = true
        // Automatic and allowed: one fix per refresh (a failed fix keeps the last one).
        if chosenLocation == .automatic, location.auth == .granted, let f = try? await location.fix() {
            fix = f
        }
        guard case .place(let lat, let lon, _) = source else { loading = false; return }
        let key = source
        let result: Result<WeatherNow, Error>
        do { result = .success(try await client.forecast(latitude: lat, longitude: lon)) } catch { result = .failure(error) }
        loading = false
        guard running, source == key else { return }
        switch result {
        case .success(let w):
            weather = w
            fetchedAt = clock()
            failures = 0
            lastError = nil
        case .failure(let error):
            failures += 1
            lastError = Self.describe(error)
        }
        schedule()
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case WeatherError.api(let reason): "Open-Meteo: \(reason)"
        case WeatherError.http(let code): "Open-Meteo answered \(code)"
        case WeatherError.malformed: "Open-Meteo's answer was unreadable"
        case WeatherError.refusedHost: "Request refused"
        default: (error as? URLError)?.code == .notConnectedToInternet ? "Offline" : "Could not reach Open-Meteo"
        }
    }

    /// The age to show: when the data is stale, or the last refresh failed or is paused.
    func ageNote(at now: Date) -> String? {
        guard let fetchedAt else { return nil }
        let age = "Updated \(WeatherFormat.age(since: fetchedAt, now: now))"
        if offline { return "Offline · \(age)" }
        if lastError != nil || WeatherRefresh.isStale(fetchedAt: fetchedAt, now: now) { return age }
        return nil
    }

    // MARK: - Sleep and network

    private func watchSleep() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAsleep(true) }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAsleep(false) }
        })
    }

    private func watchNetwork() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.setOnline(online) }
        }
        m.start(queue: DispatchQueue(label: "dev.platynotch.weather.path"))
        monitor = m
    }

    func setAsleep(_ value: Bool) {
        guard running, asleep != value else { return }
        asleep = value
        if value { task?.cancel(); task = nil } else { schedule(resuming: true) }
    }

    func setOnline(_ online: Bool) {
        guard running, offline == online else { return }
        offline = !online
        if offline { task?.cancel(); task = nil } else { schedule(resuming: true) }
    }

    // MARK: - City

    /// Looks up `query` (Settings' Search button). Only while enabled.
    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard running, let client, q.count >= 2 else {
            searchMessage = running ? "Type at least two letters." : nil
            return
        }
        searchTask?.cancel()
        searching = true
        searchMessage = nil
        searchTask = Task { @MainActor [weak self] in
            do {
                let found = try await client.places(named: q)
                guard let self, !Task.isCancelled, self.running else { return }
                self.results = found
                self.searchMessage = found.isEmpty ? "No place called “\(q)”." : nil
            } catch {
                guard let self, !Task.isCancelled, self.running else { return }
                self.results = []
                self.searchMessage = Self.describe(error)
            }
            self?.searching = false
        }
    }

    func choose(_ p: GeoPlace) {
        place = p
        if persist, let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: Self.placeKey) }
        setChosen(.city(p))
        fix = nil
        weather = nil
        fetchedAt = nil
        failures = 0
        lastAttempt = nil
        lastError = nil
        results = []
        query = ""
        searchMessage = nil
        schedule()
    }

    func clearPlace() {
        place = nil
        if persist { defaults.removeObject(forKey: Self.placeKey) }
        if case .city = chosenLocation { setChosen(nil) }
        disabled()
        task?.cancel()
        task = nil
    }

    // MARK: - Views

    func tileView() -> AnyView { AnyView(WeatherTile(widget: self)) }

    /// The Library tool: the conditions centred; "Choose a city" as a calm empty state.
    func toolView() -> AnyView {
        if place == nil {
            return AnyView(ToolEmptyState(systemImage: "cloud.sun", title: "Choose a city",
                                          detail: "Pick your city in Settings › Widgets › Weather. No location access is used."))
        }
        return AnyView(ToolPage { WeatherTile(widget: self) })
    }

    func settingsView() -> AnyView? { AnyView(WeatherSettings(widget: self)) }
}
