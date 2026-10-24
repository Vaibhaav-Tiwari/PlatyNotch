import AppKit
import Foundation
import PlatyNotchKit
import SwiftUI
import XCTest
@testable import PlatyNotchUI

/// Never the real power sources: a state the test sets, and counts of what was asked.
@MainActor
private final class FakePower: PowerSourceReading {
    var state: BatteryState?
    var reads = 0
    var starts = 0
    var stops = 0
    private var onChange: (() -> Void)?
    var watching: Bool { onChange != nil }

    init(_ state: BatteryState?) { self.state = state }

    func read() -> BatteryState? {
        reads += 1
        return state
    }

    func start(onChange: @escaping @MainActor () -> Void) {
        starts += 1
        self.onChange = onChange
    }

    func stop() {
        stops += 1
        onChange = nil
    }

    /// A power-source notification.
    func set(_ next: BatteryState?) {
        state = next
        onChange?()
    }
}

/// Never a real IOPM assertion.
@MainActor
private final class FakeAsserter: PowerAsserting {
    var active: Set<UInt32> = []
    var begun = 0
    var fail = false
    private var next: UInt32 = 1

    func begin(reason: String) -> UInt32? {
        guard !fail else { return nil }
        begun += 1
        defer { next += 1 }
        active.insert(next)
        return next
    }

    func end(_ id: UInt32) {
        active.remove(id)
    }
}

/// Never a real Bluetooth registration: the test sets the access and sends events.
@MainActor
private final class FakeHeadphones: HeadphonesSource {
    var access: BluetoothAccess = .notDetermined
    var starts = 0
    var stops = 0
    var refreshes = 0
    private var onEvent: ((HeadphonesEvent) -> Void)?
    var registered: Bool { onEvent != nil }

    func start(onEvent: @escaping @MainActor (HeadphonesEvent) -> Void) {
        starts += 1
        self.onEvent = onEvent
    }

    func stop() {
        stops += 1
        onEvent = nil
    }

    func refreshBattery() { refreshes += 1 }

    func send(_ e: HeadphonesEvent) { onEvent?(e) }
}

/// Never a real FSEvents stream: the test sends batches of paths.
@MainActor
private final class FakeWatch: FolderWatching {
    let folders: [String]
    let onPaths: @MainActor ([String]) -> Void
    var stopped = false
    init(_ folders: [String], _ onPaths: @escaping @MainActor ([String]) -> Void) {
        self.folders = folders
        self.onPaths = onPaths
    }
    func stop() { stopped = true }
}

@MainActor
private final class FakeWatches {
    var made: [FakeWatch] = []
    var live: FakeWatch? { made.last.flatMap { $0.stopped ? nil : $0 } }
    var factory: FolderWatcherFactory {
        { [unowned self] folders, onPaths in
            let w = FakeWatch(folders, onPaths)
            self.made.append(w)
            return w
        }
    }
}

@MainActor
private final class FakeFiles: FileActions {
    var opened: [URL] = []
    var revealed: [URL] = []
    func open(_ url: URL) { opened.append(url) }
    func reveal(_ url: URL) { revealed.append(url) }
}

/// Paths that exist, readable from any thread (large batches are stat'ed off main).
private final class FileSet: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Set<String> = []
    private(set) var statsOffMain = 0
    var all: Set<String> {
        get { lock.withLock { files } }
        set { lock.withLock { files = newValue } }
    }
    func stat(_ p: String) -> FileStat? {
        lock.withLock {
            if !Thread.isMainThread { statsOffMain += 1 }
            return files.contains(p) ? FileStat(size: 1) : nil
        }
    }
}

@MainActor
private final class Disk {
    let store = FileSet()
    var files: Set<String> {
        get { store.all }
        set { store.all = newValue }
    }
    var probes: [String] = []
    var allow = true
    /// The prompt stays up (the probe waits) until cancelled.
    var hold = false
    var identity = "cdhash:test-build"
    var shelf: [URL]? = nil   // nil: the shelf is off
}

@MainActor
private final class Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

private let onBattery = BatteryState(percent: 64, charging: false, pluggedIn: false, minutesRemaining: 200)
private let charging = BatteryState(percent: 64, charging: true, pluggedIn: true, minutesRemaining: 50)
private let low = BatteryState(percent: 8, charging: false, pluggedIn: false, minutesRemaining: 12)
private let airPods = HeadphonesInfo(id: "aa-bb", name: "AirPods Pro",
                                     battery: HeadphoneBattery(left: 80, right: 75, case: 40))

/// The System widget through the real registry, `PanelSurfaces` and a `NotchController`
/// (no window; the cursor is pinned). Every system service is a fake.
@MainActor
final class SystemWidgetTests: XCTestCase {
    nonisolated(unsafe) private var suites: [String] = []
    nonisolated(unsafe) private var registries: [WidgetRegistry] = []

    override func tearDown() async throws {
        await MainActor.run {
            for r in registries { r.stopAll() }   // no task or assertion outlives its test
            registries = []
            for name in suites { UserDefaults.standard.removePersistentDomain(forName: name) }
            suites = []
        }
        try await super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let name = "SystemWidgetTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    @MainActor private struct Rig {
        let widget: SystemWidget
        let registry: WidgetRegistry
        let controller: NotchController
        let power: FakePower
        let asserter: FakeAsserter
        let headphones: FakeHeadphones
        let watches: FakeWatches
        let files: FakeFiles
        let disk: Disk
        let clock: Clock
        let defaults: UserDefaults
    }

    /// `enabled: false` turns the widget off before the app starts widgets.
    private func rig(battery: BatteryState? = onBattery, enabled: Bool = true,
                     bluetooth: BluetoothAccess = .notDetermined,
                     defaults givenDefaults: UserDefaults? = nil) -> Rig {
        let d = givenDefaults ?? defaults()
        let power = FakePower(battery)
        let asserter = FakeAsserter()
        let headphones = FakeHeadphones()
        headphones.access = bluetooth
        let clock = Clock()
        let watches = FakeWatches()
        let files = FakeFiles()
        let disk = Disk()
        let store = disk.store
        let stat: @Sendable (String) -> FileStat? = { store.stat($0) }
        let probe: @MainActor (String) async -> Bool = { folder in
            disk.probes.append(folder)
            if disk.hold { try? await Task.sleep(for: .seconds(30)) }
            return disk.allow
        }
        let addToShelf: @MainActor (URL) -> Bool = { url in
            disk.shelf?.append(url)
            return true
        }
        let shelf: @MainActor () -> (@MainActor (URL) -> Bool)? = { disk.shelf == nil ? nil : addToShelf }
        let services = SystemWidget.DownloadsServices(folder: "/Users/me/Downloads", watch: watches.factory,
                                                      stat: stat, probe: probe, identity: { disk.identity },
                                                      home: "/Users/me", files: files, shelf: shelf)
        let w = SystemWidget(power: power, asserter: asserter, headphones: headphones, downloads: services,
                             defaults: d, clock: { clock.now })
        let client = CoreClient(socketPath: "/nonexistent")
        let registry = WidgetRegistry(defaults: defaults(), persist: false)
        registries.append(registry)
        let surfaces = PanelSurfaces(registry: registry)
        registry.register(w)
        if !enabled { registry.setEnabled(SystemWidget.widgetID, false) }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pnsys\(UUID().uuidString)")
        let c = NotchController(store: AppStore(), client: client, plugins: [], widgets: registry, surfaces: surfaces,
                                minimal: false)
        c.cursorLocation = { CGPoint(x: 100, y: 100) }   // never the real mouse
        registry.start(context: WidgetContext(store: AppStore(), client: client,
                                              config: ConfigFileStore(url: dir.appendingPathComponent("config.json")),
                                              events: CoreEventHub(), defaults: d, notify: NoopNotifier(),
                                              surfaces: surfaces, openPanel: { _ in }))
        return Rig(widget: w, registry: registry, controller: c, power: power, asserter: asserter,
                   headphones: headphones, watches: watches, files: files, disk: disk, clock: clock, defaults: d)
    }

    private func peek(_ id: String) -> PanelMode { .peek(.widget(id: id)) }

    // MARK: - On by default; disabled does no work

    func testOnByDefaultWithBatteryAndKeepAwakeOnly() {
        let r = rig()
        XCTAssertTrue(r.widget.defaultEnabled)
        XCTAssertTrue(r.registry.isEnabled(SystemWidget.widgetID))
        XCTAssertTrue(r.registry.running.contains(SystemWidget.widgetID))
        XCTAssertEqual(r.power.starts, 1, "one power-source run-loop source")
        XCTAssertEqual(r.widget.battery, onBattery)
        XCTAssertTrue(r.asserter.active.isEmpty, "keep-awake is never on by itself")
        XCTAssertEqual(r.asserter.begun, 0)
        XCTAssertFalse(r.widget.options.headphones, "headphones are off until turned on")
        XCTAssertEqual(r.headphones.starts, 0, "no Bluetooth registration, so no Bluetooth prompt")
        XCTAssertFalse(r.widget.options.downloads, "downloads are off until turned on")
        XCTAssertTrue(r.watches.made.isEmpty, "no FSEvents stream")
        XCTAssertTrue(r.disk.probes.isEmpty, "the Downloads folder is never touched, so no prompt")
    }

    func testDisabledDoesNoWork() {
        let r = rig(enabled: false)
        XCTAssertFalse(r.registry.running.contains(SystemWidget.widgetID))
        XCTAssertEqual(r.power.reads, 0, "no power reads")
        XCTAssertEqual(r.power.starts, 0, "no run-loop source")
        r.widget.startKeepAwake(.thirtyMinutes)
        XCTAssertEqual(r.asserter.begun, 0, "no assertion while off")
        XCTAssertTrue(r.widget.liveActivities.isEmpty)

        r.registry.setEnabled(SystemWidget.widgetID, true)
        XCTAssertEqual(r.power.starts, 1)
        r.widget.startKeepAwake(.untilOff)
        XCTAssertEqual(r.asserter.active.count, 1)

        r.registry.setEnabled(SystemWidget.widgetID, false)
        XCTAssertFalse(r.power.watching, "the run-loop source is removed")
        XCTAssertEqual(r.power.stops, 1)
        XCTAssertTrue(r.asserter.active.isEmpty, "turning the widget off releases the assertion")
        XCTAssertNil(r.widget.keepAwake.session)
        XCTAssertTrue(r.widget.liveActivities.isEmpty)
        r.power.set(charging)
        XCTAssertEqual(r.power.reads, 1, "no reads after stop (only the one at start)")
    }

    // MARK: - Battery

    func testPlugInAndUnplugPeek() {
        let r = rig()
        XCTAssertEqual(r.controller.mode, .compact, "the first reading at start is no peek")
        r.power.set(charging)
        XCTAssertEqual(r.widget.powerPeek?.change, .pluggedIn)
        XCTAssertEqual(r.widget.powerPeek?.state.percent, 64)
        XCTAssertEqual(r.controller.mode, peek(SystemWidget.powerPeekID))
        XCTAssertNotNil(r.registry.peekView(id: SystemWidget.powerPeekID))

        r.power.set(onBattery)
        XCTAssertEqual(r.widget.powerPeek?.change, .unplugged)
        XCTAssertEqual(r.controller.mode, peek(SystemWidget.powerPeekID))

        var step = onBattery
        step.percent = 63
        r.widget.dismissPowerPeek()
        r.power.set(step)
        XCTAssertNil(r.widget.powerPeek, "a percent step is no peek")
        XCTAssertEqual(r.widget.battery?.percent, 63)
    }

    func testLowBatteryIsLiveAndChargingIsAmbient() {
        let r = rig(battery: low)
        let lowActivity = r.widget.liveActivities.first { $0.id == SystemWidget.batteryActivityID }
        XCTAssertEqual(lowActivity?.priority, LivePriority.batteryLow)
        XCTAssertEqual(lowActivity?.tint, .critical)
        XCTAssertEqual(lowActivity?.trailing, "8%")
        XCTAssertTrue(LiveArbiter.hasLive(r.registry.liveActivities, now: r.clock.now), "low battery keeps Minimal up")

        r.power.set(charging)
        let chargingActivity = r.widget.liveActivities.first { $0.id == SystemWidget.batteryActivityID }
        XCTAssertEqual(chargingActivity?.priority, LivePriority.batteryCharging)
        XCTAssertEqual(chargingActivity?.isAmbient, true)
        XCTAssertFalse(LiveArbiter.hasLive(r.registry.liveActivities, now: r.clock.now),
                       "charging is ambient (C9): never keeps Minimal up")

        r.power.set(onBattery)
        XCTAssertTrue(r.widget.liveActivities.isEmpty, "64% on battery shows nothing in the pill")
    }

    func testDesktopMacShowsNoBattery() {
        let r = rig(battery: nil)
        XCTAssertNil(r.widget.battery)
        XCTAssertEqual(r.power.starts, 0, "no run-loop source without a battery")
        XCTAssertTrue(r.widget.liveActivities.isEmpty)
        let tile = NSHostingView(rootView: r.widget.tileView().frame(width: 360))
        tile.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tile.fittingSize.width, 0, "the tile still builds (keep-awake only)")
    }

    // MARK: - Keep awake

    func testKeepAwakeHoldsUntilExpiry() {
        let r = rig()
        r.widget.startKeepAwake(.thirtyMinutes)
        XCTAssertEqual(r.asserter.active.count, 1)
        let a = r.widget.liveActivities.first { $0.id == SystemWidget.keepAwakeActivityID }
        XCTAssertEqual(a?.priority, LivePriority.keepAwake)
        XCTAssertEqual(a?.countdownTo, r.clock.now.addingTimeInterval(1800), "the pill counts down the time left")
        XCTAssertEqual(a?.expiresAt, a?.countdownTo)

        r.clock.advance(29 * 60)
        r.widget.keepAwake.checkExpiry()
        XCTAssertEqual(r.asserter.active.count, 1, "not yet")
        r.clock.advance(60)
        r.widget.keepAwake.checkExpiry()
        XCTAssertTrue(r.asserter.active.isEmpty, "expiry releases the assertion")
        XCTAssertNil(r.widget.keepAwake.session)
        XCTAssertNil(r.widget.liveActivities.first { $0.id == SystemWidget.keepAwakeActivityID })
    }

    func testKeepAwakeUntilOffAndReplace() {
        let r = rig()
        r.widget.startKeepAwake(.thirtyMinutes)
        r.widget.startKeepAwake(.twoHours)
        XCTAssertEqual(r.asserter.begun, 1, "changing the time keeps the one assertion")
        XCTAssertEqual(r.widget.keepAwake.session?.duration, .twoHours)
        r.widget.startKeepAwake(.untilOff)
        let a = r.widget.liveActivities.first { $0.id == SystemWidget.keepAwakeActivityID }
        XCTAssertNil(a?.countdownTo)
        XCTAssertEqual(a?.trailing, "On")
        r.clock.advance(1e6)
        r.widget.keepAwake.checkExpiry()
        XCTAssertEqual(r.asserter.active.count, 1, "until off never expires")
        r.widget.stopKeepAwake()
        XCTAssertTrue(r.asserter.active.isEmpty)
    }

    func testKeepAwakeReleasedOnQuitAndNeverRecreated() {
        let d = defaults()
        let r = rig(defaults: d)
        r.widget.startKeepAwake(.oneHour)
        r.registry.stopAll()   // quit
        XCTAssertTrue(r.asserter.active.isEmpty, "quitting releases the assertion")

        let relaunched = rig(defaults: d)
        XCTAssertEqual(relaunched.asserter.begun, 0, "a timed keep-awake does not survive a relaunch")
        XCTAssertNil(relaunched.widget.keepAwake.session)
    }

    func testKeepAwakeRefusedAssertion() {
        let r = rig()
        r.asserter.fail = true
        r.widget.startKeepAwake(.oneHour)
        XCTAssertNil(r.widget.keepAwake.session, "no countdown without the assertion")
        XCTAssertTrue(r.widget.liveActivities.isEmpty)
        XCTAssertNotNil(r.widget.keepAwake.lastError)
    }

    // MARK: - Headphones (opt-in sub-feature)

    private func savedOptions(_ o: SystemWidget.Options) -> UserDefaults {
        let d = defaults()
        d.set(try! JSONEncoder().encode(o), forKey: SystemWidget.Options.key)
        return d
    }

    func testHeadphonesButtonRegistersAndTurningOffUnregisters() {
        let r = rig()
        r.widget.setHeadphones(true)   // the settings button: the only place the prompt can appear
        XCTAssertEqual(r.headphones.starts, 1, "registers for connect notifications (may prompt here)")
        XCTAssertTrue(r.widget.options.headphones)

        r.headphones.send(.connected(airPods))
        XCTAssertEqual(r.widget.headphones, [airPods])
        XCTAssertEqual(r.widget.headphonesPeek, airPods)
        XCTAssertEqual(r.controller.mode, peek(SystemWidget.headphonesPeekID), "connect peek with the device name")
        XCTAssertNotNil(r.registry.peekView(id: SystemWidget.headphonesPeekID))

        var updated = airPods
        updated.battery = HeadphoneBattery(left: 70, right: 70)
        r.headphones.send(.updated(updated))
        XCTAssertEqual(r.widget.headphones.first?.battery.left, 70)

        r.headphones.send(.disconnected(id: airPods.id))
        XCTAssertTrue(r.widget.headphones.isEmpty)

        r.widget.setHeadphones(false)
        XCTAssertFalse(r.headphones.registered, "turning it off unregisters")
        XCTAssertEqual(r.headphones.stops, 1)
        XCTAssertFalse(r.widget.options.headphones)
        let saved = SystemWidget.Options.load(r.defaults)
        XCTAssertEqual(saved.headphones, false)
    }

    func testAlreadyConnectedHeadphonesAreListedWithoutAPeek() {
        let r = rig(bluetooth: .allowed)
        r.widget.setHeadphones(true)
        r.headphones.send(.present(airPods))
        XCTAssertEqual(r.widget.headphones, [airPods])
        XCTAssertNil(r.widget.headphonesPeek)
        XCTAssertEqual(r.controller.mode, .compact)
        r.headphones.send(.connected(airPods))
        XCTAssertNil(r.widget.headphonesPeek, "a device already listed is no new connection")
    }

    func testHeadphonesAtLaunchNeverPrompt() {
        let on = SystemWidget.Options(headphones: true)
        let notAsked = rig(bluetooth: .notDetermined, defaults: savedOptions(on))
        XCTAssertEqual(notAsked.headphones.starts, 0, "not allowed yet: nothing registers at launch (no prompt)")
        XCTAssertTrue(notAsked.widget.headphonesNeedAccess)
        notAsked.widget.requestHeadphonesAccess()   // the button
        XCTAssertEqual(notAsked.headphones.starts, 1)

        let denied = rig(bluetooth: .denied, defaults: savedOptions(on))
        XCTAssertEqual(denied.headphones.starts, 0)
        XCTAssertTrue(denied.widget.headphonesNeedAccess)

        let allowed = rig(bluetooth: .allowed, defaults: savedOptions(on))
        XCTAssertEqual(allowed.headphones.starts, 1, "allowed before: registers at launch")
        XCTAssertFalse(allowed.widget.headphonesNeedAccess)
    }

    func testHeadphonesStopWithTheWidget() {
        let r = rig(bluetooth: .allowed, defaults: savedOptions(.init(headphones: true)))
        XCTAssertTrue(r.headphones.registered)
        r.headphones.send(.connected(airPods))
        r.registry.setEnabled(SystemWidget.widgetID, false)
        XCTAssertFalse(r.headphones.registered, "the widget off: no Bluetooth notifications")
        XCTAssertTrue(r.widget.headphones.isEmpty)
        XCTAssertNotEqual(r.controller.mode, peek(SystemWidget.headphonesPeekID))
        r.widget.setHeadphones(true)
        XCTAssertEqual(r.headphones.starts, 1, "the sub-feature cannot start while the widget is off")
        XCTAssertTrue(r.widget.options.headphones)
    }

    func testHeadphonesBatteryHiddenWhenAbsent() {
        let r = rig(bluetooth: .allowed)
        r.widget.setHeadphones(true)
        let noBattery = HeadphonesInfo(id: "cc", name: "Sony WH-1000XM5", battery: HeadphoneBattery())
        r.headphones.send(.connected(noBattery))
        XCTAssertNil(r.widget.headphones.first?.battery.summary)
        let tile = NSHostingView(rootView: r.widget.tileView().frame(width: 360))
        tile.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tile.fittingSize.width, 0)
        let peekView = NSHostingView(rootView: r.registry.peekView(id: SystemWidget.headphonesPeekID)!.frame(width: 360))
        peekView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(peekView.fittingSize.width, 0)
    }

    // MARK: - Downloads (opt-in sub-feature)

    private let folder = "/Users/me/Downloads"

    private func turnOnDownloads(_ r: Rig) async {
        r.widget.setDownloads(true)
        await r.widget.downloadsTask?.value
    }

    func testDownloadsButtonAsksThenWatches() async {
        let r = rig()
        await turnOnDownloads(r)
        XCTAssertEqual(r.disk.probes, [folder], "the button is where the Downloads prompt can appear")
        XCTAssertEqual(r.watches.live?.folders, [folder], "~/Downloads only")
        XCTAssertTrue(r.widget.options.downloads)
        XCTAssertEqual(SystemWidget.Options.load(r.defaults).downloads, true)

        let temp = "\(folder)/report.pdf.crdownload", final = "\(folder)/report.pdf"
        r.disk.files = [temp]
        r.watches.live?.onPaths([temp])
        let a = r.widget.liveActivities.first { $0.id == SystemWidget.downloadActivityID }
        XCTAssertEqual(a?.priority, LivePriority.download)
        XCTAssertEqual(a?.trailing, "report.pdf", "the in-progress activity shows the file name")
        XCTAssertEqual(r.widget.downloadsActive.map(\.name), ["report.pdf"])

        r.disk.files = [final]
        r.watches.live?.onPaths([temp, final])
        XCTAssertNil(r.widget.liveActivities.first { $0.id == SystemWidget.downloadActivityID })
        XCTAssertEqual(r.widget.finishedDownload, URL(fileURLWithPath: final))
        XCTAssertEqual(r.controller.mode, peek(SystemWidget.downloadPeekID), "a finished notice")
        XCTAssertNotNil(r.registry.peekView(id: SystemWidget.downloadPeekID))
        XCTAssertTrue(r.files.opened.isEmpty && r.files.revealed.isEmpty, "nothing is done without a click")

        r.widget.openDownload()
        r.widget.revealDownload()
        XCTAssertEqual(r.files.opened, [URL(fileURLWithPath: final)])
        XCTAssertEqual(r.files.revealed, [URL(fileURLWithPath: final)])
    }

    func testAddToShelfOnlyWhenTheShelfIsOn() async {
        let r = rig()
        await turnOnDownloads(r)
        let final = "\(folder)/a.zip"
        r.disk.files = [final]
        r.watches.live?.onPaths(["\(folder)/a.zip.crdownload", final])
        XCTAssertFalse(r.widget.canMoveToShelf, "the shelf is off: no Add to Shelf")
        XCTAssertFalse(r.widget.addDownloadToShelf())

        r.disk.shelf = []
        XCTAssertTrue(r.widget.canMoveToShelf)
        XCTAssertTrue(r.widget.addDownloadToShelf())
        XCTAssertEqual(r.disk.shelf, [URL(fileURLWithPath: final)])
    }

    func testDownloadsDeniedPersistsAndWatchesNothing() async {
        let d = defaults()
        let r = rig(defaults: d)
        r.disk.allow = false
        await turnOnDownloads(r)
        XCTAssertTrue(r.watches.made.isEmpty)
        XCTAssertTrue(r.widget.downloadsDenied)
        XCTAssertFalse(r.widget.options.downloads, "never \"on\" while nothing works")
        let saved = SystemWidget.Options.load(d)
        XCTAssertTrue(saved.downloadsDenied, "denied is saved")
        XCTAssertFalse(saved.downloads)

        let relaunched = rig(defaults: d)
        XCTAssertTrue(relaunched.widget.downloadsDenied, "Settings still says macOS refused")
        XCTAssertTrue(relaunched.watches.made.isEmpty)
        XCTAssertTrue(relaunched.disk.probes.isEmpty)
    }

    func testDownloadsAtLaunchWatchWithoutAsking() {
        let on = SystemWidget.Options(downloads: true, extraFolder: "/Users/me/Incoming", downloadsStamp: "cdhash:test-build")
        let r = rig(defaults: savedOptions(on))
        XCTAssertTrue(r.disk.probes.isEmpty, "no folder listing at launch")
        XCTAssertEqual(r.watches.live?.folders, [folder, "/Users/me/Incoming"], "plus the chosen folder")
    }

    func testStampMismatchStartsNothing() {
        let d = savedOptions(.init(downloads: true, downloadsStamp: "cdhash:old-build"))
        let r = rig(defaults: d)
        XCTAssertTrue(r.watches.made.isEmpty, "another build was granted: no stream, no stat")
        XCTAssertTrue(r.disk.probes.isEmpty)
        XCTAssertEqual(r.disk.store.statsOffMain, 0)
        XCTAssertFalse(r.widget.options.downloads, "kept off until Turn On again")
        XCTAssertTrue(r.widget.options.downloadsNeedReenable, "Settings says why")
        XCTAssertFalse(SystemWidget.Options.load(d).downloads)

        let noStamp = rig(defaults: savedOptions(.init(downloads: true)))
        XCTAssertTrue(noStamp.watches.made.isEmpty, "a missing stamp counts as a different build")
        XCTAssertTrue(noStamp.widget.options.downloadsNeedReenable)
    }

    func testQuitWhileThePromptIsUpLeavesDownloadsOff() async {
        let d = defaults()
        let r = rig(defaults: d)
        r.disk.hold = true
        r.widget.setDownloads(true)
        XCTAssertTrue(r.widget.downloadsAsking)
        XCTAssertFalse(r.widget.options.downloads, "not saved before macOS answers")
        XCTAssertFalse(SystemWidget.Options.load(d).downloads)
        let task = r.widget.downloadsTask
        r.registry.stopAll()   // quit
        await task?.value
        XCTAssertFalse(SystemWidget.Options.load(d).downloads, "still off after quitting mid-prompt")
        XCTAssertNil(SystemWidget.Options.load(d).downloadsStamp)
        XCTAssertTrue(r.watches.made.isEmpty)
    }

    func testGrantSavesTheStamp() async {
        let d = defaults()
        let r = rig(defaults: d)
        await turnOnDownloads(r)
        XCTAssertEqual(SystemWidget.Options.load(d).downloadsStamp, "cdhash:test-build")
        r.widget.setDownloads(false)
        XCTAssertNil(SystemWidget.Options.load(d).downloadsStamp, "turning off forgets the grant")
    }

    func testProtectedSecondFolderIsRejected() async {
        let r = rig()
        await turnOnDownloads(r)
        XCTAssertFalse(r.widget.setExtraFolder("/Users/me/Desktop/In"))
        XCTAssertNotNil(r.widget.extraFolderRejection, "a clear reason in Settings")
        XCTAssertNil(r.widget.options.extraFolder)
        XCTAssertEqual(r.watches.made.count, 1, "the watch is unchanged")
        XCTAssertFalse(r.widget.setExtraFolder("/Volumes/USB"))
        XCTAssertTrue(r.widget.setExtraFolder("/Users/me/Incoming"))
        XCTAssertNil(r.widget.extraFolderRejection)

        // Saved by an older build: dropped at launch, with the reason, before any stat.
        let old = SystemWidget.Options(downloads: true, extraFolder: "/Users/me/Documents/DL",
                                       downloadsStamp: "cdhash:test-build")
        let relaunched = rig(defaults: savedOptions(old))
        XCTAssertEqual(relaunched.watches.live?.folders, [folder])
        XCTAssertNil(relaunched.widget.options.extraFolder)
        XCTAssertNotNil(relaunched.widget.extraFolderRejection)
    }

    func testLargeBatchIsStatedOffTheMainThread() async {
        let r = rig()
        await turnOnDownloads(r)
        let names = (0..<100).map { "\(folder)/f\($0).crdownload" }
        r.disk.files = Set(names)
        r.watches.live?.onPaths(names)
        await r.widget.downloadsPendingBatch?.value
        XCTAssertEqual(r.widget.downloadsActive.count, 100)
        XCTAssertGreaterThan(r.disk.store.statsOffMain, 0)
        XCTAssertEqual(r.widget.liveActivities.first { $0.id == SystemWidget.downloadActivityID }?.trailing,
                       "f99.crdownload".replacingOccurrences(of: ".crdownload", with: "") + " +99")
        XCTAssertNotEqual(SystemWidget.downloadActivityID, SystemWidget.downloadPeekID)
    }

    // MARK: - Power fixes

    func testPlugBurstPeeksOnceWithTheLastState() {
        let r = rig()
        r.power.set(charging)
        XCTAssertEqual(r.widget.powerPeek?.change, .pluggedIn)
        r.clock.advance(0.5)
        r.power.set(onBattery)
        XCTAssertEqual(r.widget.powerPeek?.change, .unplugged, "the peek on show follows the last state")
        r.clock.advance(0.5)
        r.power.set(charging)
        XCTAssertEqual(r.widget.powerPeek?.change, .pluggedIn)
        XCTAssertEqual(r.controller.mode, peek(SystemWidget.powerPeekID))
    }

    func testBatteryReadRetriedOnceWhenMissingAtStart() {
        let r = rig(battery: nil)
        XCTAssertEqual(r.power.starts, 0)
        r.power.state = onBattery
        r.widget.retryBatteryRead()
        XCTAssertEqual(r.widget.battery, onBattery)
        XCTAssertEqual(r.power.starts, 1, "a laptop whose first read failed gets its source")
        r.widget.retryBatteryRead()
        XCTAssertEqual(r.power.starts, 1, "once")
    }

    func testDownloadsStopWithTheWidgetAndTurnOff() async {
        let r = rig()
        await turnOnDownloads(r)
        let temp = "\(folder)/x.iso.crdownload"
        r.disk.files = [temp]
        r.watches.live?.onPaths([temp])
        XCTAssertFalse(r.widget.downloadsActive.isEmpty)

        r.registry.setEnabled(SystemWidget.widgetID, false)
        XCTAssertTrue(r.watches.made.allSatisfy(\.stopped), "the widget off: no FSEvents stream")
        XCTAssertTrue(r.widget.downloadsActive.isEmpty)
        XCTAssertTrue(r.widget.liveActivities.isEmpty)
        r.watches.made.last?.onPaths([temp])
        XCTAssertTrue(r.widget.downloadsActive.isEmpty, "late batches are ignored")

        r.registry.setEnabled(SystemWidget.widgetID, true)
        XCTAssertNotNil(r.watches.live, "on again: watching again (already allowed)")
        r.widget.setDownloads(false)
        XCTAssertNil(r.watches.live, "turned off: stream stopped")
        XCTAssertEqual(SystemWidget.Options.load(r.defaults).downloads, false)
    }

    func testChoosingASecondFolderRestartsTheWatch() async {
        let r = rig()
        await turnOnDownloads(r)
        r.widget.setExtraFolder("/Users/me/Incoming")
        XCTAssertEqual(r.watches.made.count, 2)
        XCTAssertTrue(r.watches.made[0].stopped)
        XCTAssertEqual(r.watches.live?.folders, [folder, "/Users/me/Incoming"])
        r.widget.setExtraFolder(nil)
        XCTAssertEqual(r.watches.live?.folders, [folder])
    }

    func testCodeIdentityIsStableWithinALaunch() {
        let id = CodeIdentity.current
        XCTAssertTrue(id.hasPrefix("cdhash:") || id.hasPrefix("dr:") || id == CodeIdentity.unsigned, id)
        XCTAssertEqual(id, CodeIdentity.current)
        print("CodeIdentity under swift test: \(id.prefix(20))…")
    }
}
