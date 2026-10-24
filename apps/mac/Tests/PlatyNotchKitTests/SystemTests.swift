import Foundation
import PlatyNotchKit
import XCTest

/// Task 9's pure logic: battery state, keep-awake sessions, headphone battery and the
/// downloads detector. Uses only the public API (the UI target sees nothing more, C6).
final class SystemTests: XCTestCase {
    // MARK: - Battery

    func testBatteryLow() {
        XCTAssertTrue(BatteryState(percent: 10, charging: false, pluggedIn: false, minutesRemaining: 20).isLow,
                      "10% unplugged is low")
        XCTAssertFalse(BatteryState(percent: 10, charging: true, pluggedIn: true, minutesRemaining: nil).isLow,
                       "10% plugged in is not low")
        XCTAssertFalse(BatteryState(percent: 10, charging: false, pluggedIn: true, minutesRemaining: nil).isLow,
                       "plugged in but not charging (optimised charging) is not low")
        XCTAssertFalse(BatteryState(percent: 11, charging: false, pluggedIn: false, minutesRemaining: nil).isLow)
        XCTAssertTrue(BatteryState(percent: 0, charging: false, pluggedIn: false, minutesRemaining: nil).isLow)
    }

    private func source(_ fields: [String: Any]) -> [String: Any] {
        var d: [String: Any] = ["Type": "InternalBattery", "Is Present": true, "Current Capacity": 72,
                                "Max Capacity": 100, "Is Charging": false, "Power Source State": "Battery Power",
                                "Time to Empty": 185, "Time to Full Charge": -1]
        for (k, v) in fields { d[k] = v }
        return d
    }

    func testBatteryFromPowerSourceDescription() {
        let onBattery = BatteryState.internalBattery(from: [source([:])])
        XCTAssertEqual(onBattery, BatteryState(percent: 72, charging: false, pluggedIn: false, minutesRemaining: 185))

        let charging = BatteryState.internalBattery(from: [source(["Is Charging": true, "Power Source State": "AC Power",
                                                                   "Time to Empty": 0, "Time to Full Charge": 48])])
        XCTAssertEqual(charging, BatteryState(percent: 72, charging: true, pluggedIn: true, minutesRemaining: 48),
                       "while charging the time is until full")

        let full = BatteryState.internalBattery(from: [source(["Current Capacity": 100, "Power Source State": "AC Power",
                                                               "Time to Full Charge": 0])])
        XCTAssertEqual(full, BatteryState(percent: 100, charging: false, pluggedIn: true, minutesRemaining: nil),
                       "full on AC: no time")

        let calculating = BatteryState.internalBattery(from: [source(["Time to Empty": -1])])
        XCTAssertNil(calculating?.minutesRemaining, "-1 means still calculating")
    }

    func testBatteryPercentScalesByMaxCapacity() {
        // Some Macs report mAh rather than percent.
        let s = BatteryState.internalBattery(from: [source(["Current Capacity": 2500, "Max Capacity": 5000])])
        XCTAssertEqual(s?.percent, 50)
        let over = BatteryState.internalBattery(from: [source(["Current Capacity": 120, "Max Capacity": 100])])
        XCTAssertEqual(over?.percent, 100, "clamped")
    }

    func testDesktopHasNoBattery() {
        XCTAssertNil(BatteryState.internalBattery(from: []), "a Mac mini lists no power source")
        let ups: [String: Any] = ["Type": "UPS", "Current Capacity": 90, "Max Capacity": 100,
                                  "Power Source State": "AC Power"]
        XCTAssertNil(BatteryState.internalBattery(from: [ups]), "a UPS is not the Mac's battery")
        XCTAssertNil(BatteryState.internalBattery(from: [source(["Is Present": false])]), "battery removed")
        XCTAssertNil(BatteryState.internalBattery(from: [["Type": "InternalBattery"]]), "no capacity: nothing to show")
        XCTAssertEqual(BatteryState.internalBattery(from: [ups, source([:])])?.percent, 72, "the internal one wins")
    }

    func testPlugInAndUnplugChanges() {
        let onBattery = BatteryState(percent: 50, charging: false, pluggedIn: false, minutesRemaining: 100)
        let plugged = BatteryState(percent: 50, charging: true, pluggedIn: true, minutesRemaining: 60)
        XCTAssertEqual(BatteryState.change(from: onBattery, to: plugged), .pluggedIn)
        XCTAssertEqual(BatteryState.change(from: plugged, to: onBattery), .unplugged)
        XCTAssertNil(BatteryState.change(from: nil, to: plugged), "the first reading at start is no peek")
        XCTAssertNil(BatteryState.change(from: plugged, to: nil))
        var charged = plugged
        charged.percent = 51
        XCTAssertNil(BatteryState.change(from: plugged, to: charged), "a percent step is no peek")
        charged.charging = false
        XCTAssertNil(BatteryState.change(from: plugged, to: charged), "charging pausing on AC is no peek")
    }

    func testBatteryText() {
        let charging = BatteryState(percent: 72, charging: true, pluggedIn: true, minutesRemaining: 65)
        XCTAssertEqual(charging.statusText, "Charging · 1 h 5 min until full")
        let onBattery = BatteryState(percent: 72, charging: false, pluggedIn: false, minutesRemaining: 45)
        XCTAssertEqual(onBattery.statusText, "On battery · 45 min left")
        let full = BatteryState(percent: 100, charging: false, pluggedIn: true, minutesRemaining: nil)
        XCTAssertEqual(full.statusText, "Plugged in")
        let calculating = BatteryState(percent: 40, charging: false, pluggedIn: false, minutesRemaining: nil)
        XCTAssertEqual(calculating.statusText, "On battery")
        XCTAssertEqual(BatteryState(percent: 8, charging: false, pluggedIn: false, minutesRemaining: nil).symbolName,
                       "battery.0percent")
        XCTAssertEqual(charging.symbolName, "battery.100percent.bolt")
        XCTAssertEqual(onBattery.symbolName, "battery.75percent")
    }

    // MARK: - Keep awake

    func testKeepAwakeDurations() {
        XCTAssertEqual(KeepAwakeDuration.allCases, [.thirtyMinutes, .oneHour, .twoHours, .untilOff])
        XCTAssertEqual(KeepAwakeDuration.thirtyMinutes.interval, 30 * 60)
        XCTAssertEqual(KeepAwakeDuration.oneHour.interval, 60 * 60)
        XCTAssertEqual(KeepAwakeDuration.twoHours.interval, 2 * 60 * 60)
        XCTAssertNil(KeepAwakeDuration.untilOff.interval)
        XCTAssertEqual(KeepAwakeDuration.allCases.map(\.label), ["30 minutes", "1 hour", "2 hours", "Until turned off"])
    }

    func testKeepAwakeSessionRemainingAndExpiry() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let s = KeepAwakeSession(duration: .thirtyMinutes, now: t0)
        XCTAssertEqual(s.until, t0.addingTimeInterval(1800))
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(600)), 1200)
        XCTAssertFalse(s.isExpired(at: t0.addingTimeInterval(1799)))
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(1800)), "expires exactly at the end")
        XCTAssertEqual(s.remaining(at: t0.addingTimeInterval(4000)), 0, "never negative")

        let forever = KeepAwakeSession(duration: .untilOff, now: t0)
        XCTAssertNil(forever.until)
        XCTAssertNil(forever.remaining(at: t0.addingTimeInterval(1e7)))
        XCTAssertFalse(forever.isExpired(at: t0.addingTimeInterval(1e7)), "until off never expires")
    }

    // MARK: - Headphones

    func testHeadphoneBatteryKeys() {
        let b = HeadphoneBattery(values: ["BatteryPercentLeft": 80, "BatteryPercentRight": 75,
                                          "BatteryPercentCase": 40, "BatteryPercentSingle": 0])
        XCTAssertEqual(b.left, 80)
        XCTAssertEqual(b.right, 75)
        XCTAssertEqual(b.case, 40)
        XCTAssertNil(b.single, "0 means not reported")
        XCTAssertFalse(b.isEmpty)
        XCTAssertEqual(b.summary, "L 80% · R 75% · Case 40%")
        XCTAssertEqual(b.lowest, 75)
    }

    func testHeadphoneBatteryAbsentIsHidden() {
        let none = HeadphoneBattery(values: [:])
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(none.summary, "no battery keys: the battery is hidden")
        let junk = HeadphoneBattery(values: ["BatteryPercentLeft": 0, "BatteryPercentRight": 255, "Other": 50])
        XCTAssertTrue(junk.isEmpty, "0 and out-of-range values are not readings")
        let single = HeadphoneBattery(values: ["BatteryPercentSingle": 55])
        XCTAssertEqual(single.summary, "55%")
        let budsOnly = HeadphoneBattery(values: ["BatteryPercentLeft": 30])
        XCTAssertEqual(budsOnly.summary, "L 30%")
    }

    func testHeadphonesFilter() {
        XCTAssertTrue(HeadphoneKind.isHeadphones(majorClass: 0x04, name: "Sony WH-1000XM5"), "audio major class")
        XCTAssertTrue(HeadphoneKind.isHeadphones(majorClass: 0, name: "Vaibhaav’s AirPods Pro"), "by name")
        XCTAssertTrue(HeadphoneKind.isHeadphones(majorClass: 0, name: "Beats Studio Buds"))
        XCTAssertFalse(HeadphoneKind.isHeadphones(majorClass: 0x05, name: "Magic Keyboard"), "peripheral")
        XCTAssertFalse(HeadphoneKind.isHeadphones(majorClass: 0x02, name: "iPhone"), "phone")
        XCTAssertFalse(HeadphoneKind.isHeadphones(majorClass: 0, name: nil))
    }

    func testKeepAwakeSessionExpiresAcrossClockJumps() {
        // The deadline is a wall-clock date: a Mac asleep past it is expired on wake.
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let s = KeepAwakeSession(duration: .oneHour, now: t0)
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(5 * 3600)))
    }

    // MARK: - Downloads

    func testDownloadSuffixes() {
        for name in ["report.pdf.crdownload", "Unconfirmed 123.crdownload", "movie.mov.download", "a.zip.part",
                     "a.zip.partial", "a.dmg.opdownload", "UPPER.PDF.CRDOWNLOAD"] {
            XCTAssertEqual(DownloadDetector.state(fileName: name), .inProgress, name)
        }
        for name in ["report.pdf", "archive.zip", "notes.txt", "crdownload", "a.downloads", "part.pdf"] {
            XCTAssertEqual(DownloadDetector.state(fileName: name), .done, name)
        }
        XCTAssertEqual(DownloadDetector.finalName(for: "report.pdf.crdownload"), "report.pdf")
        XCTAssertEqual(DownloadDetector.finalName(for: "movie.mov.download"), "movie.mov")
        XCTAssertEqual(DownloadDetector.finalName(for: "report.pdf"), "report.pdf")
        XCTAssertTrue(DownloadDetector.isIgnored(fileName: ".DS_Store"))
        XCTAssertTrue(DownloadDetector.isIgnored(fileName: ".com.google.Chrome.abc123"))
        XCTAssertFalse(DownloadDetector.isIgnored(fileName: "report.pdf"))
    }

    func testDownloadShortName() {
        XCTAssertEqual(DownloadDetector.shortName("report.pdf"), "report.pdf")
        XCTAssertEqual(DownloadDetector.shortName("a-very-long-file-name-indeed.pdf", max: 16), "a-very-long-fil…")
    }

    func testDownloadEntryMapping() {
        let folders = ["/Users/me/Downloads"]
        XCTAssertEqual(DownloadDetector.entry(path: "/Users/me/Downloads/a.pdf", folders: folders),
                       "/Users/me/Downloads/a.pdf")
        XCTAssertEqual(DownloadDetector.entry(path: "/Users/me/Downloads/a.pdf.download/a.pdf", folders: folders),
                       "/Users/me/Downloads/a.pdf.download", "writes inside Safari's bundle count for the bundle")
        XCTAssertNil(DownloadDetector.entry(path: "/Users/me/Downloads/Project/file.txt", folders: folders),
                     "subfolders are not downloads")
        XCTAssertNil(DownloadDetector.entry(path: "/Users/me/Downloads", folders: folders))
        XCTAssertNil(DownloadDetector.entry(path: "/Users/me/Downloadsextra/a.pdf", folders: folders))
        XCTAssertEqual(DownloadDetector.entry(path: "/Volumes/Data/In/x.zip", folders: folders + ["/Volumes/Data/In/"]),
                       "/Volumes/Data/In/x.zip", "a trailing slash on a folder is fine")
    }

    private let dl = "/Users/me/Downloads"
    private let t0 = Date(timeIntervalSince1970: 3_000_000)

    /// Runs batches against a set of paths that exist (size 1 unless listed in `empty`).
    private struct Disk {
        var files: Set<String> = []
        var empty: Set<String> = []
        func stat(_ p: String) -> FileStat? { files.contains(p) ? FileStat(size: empty.contains(p) ? 0 : 1) : nil }
    }

    func testChromeRenameSequence() {
        var tracker = DownloadTracker(folders: [dl])
        var disk = Disk()
        let temp = "\(dl)/Unconfirmed 123.crdownload", named = "\(dl)/report.pdf.crdownload", final = "\(dl)/report.pdf"
        disk.files = [temp]
        XCTAssertEqual(tracker.apply(paths: [temp], stat: disk.stat, now: t0).map(\.kind), [.started])
        XCTAssertEqual(tracker.active.map(\.name), ["Unconfirmed 123"])

        disk.files = [named]
        let renamed = tracker.apply(paths: [temp, named], stat: disk.stat, now: t0 + 1)
        XCTAssertEqual(renamed.map(\.kind), [.ended, .started], "the unconfirmed name goes, the real one starts")
        XCTAssertEqual(tracker.active.map(\.name), ["report.pdf"], "the live activity shows the file name")

        XCTAssertEqual(tracker.apply(paths: [named], stat: disk.stat, now: t0 + 2), [], "writes: nothing new")

        disk.files = [final]
        let done = tracker.apply(paths: [named, final], stat: disk.stat, now: t0 + 30)
        XCTAssertEqual(done, [.init(kind: .ended, path: named), .init(kind: .finished, path: final)])
        XCTAssertTrue(tracker.active.isEmpty)
    }

    func testFastDownloadInOneBatch() {
        var tracker = DownloadTracker(folders: [dl])
        let disk = Disk(files: ["\(dl)/tiny.png"])
        let events = tracker.apply(paths: ["\(dl)/tiny.png.crdownload", "\(dl)/tiny.png"], stat: disk.stat, now: t0)
        XCTAssertEqual(events, [.init(kind: .finished, path: "\(dl)/tiny.png")],
                       "created and renamed within one coalesced batch")
    }

    func testSafariBundleSequence() {
        var tracker = DownloadTracker(folders: [dl])
        var disk = Disk()
        let bundle = "\(dl)/movie.mov.download", final = "\(dl)/movie.mov"
        disk.files = [bundle]
        XCTAssertEqual(tracker.apply(paths: ["\(bundle)/Info.plist", "\(bundle)/movie.mov"], stat: disk.stat,
                                     now: t0).map(\.kind), [.started])
        // Safari moves the file out first, then removes the bundle in a later batch.
        disk.files = [bundle, final]
        XCTAssertEqual(tracker.apply(paths: [final], stat: disk.stat, now: t0 + 5), [],
                       "the final name while its download is still in progress: wait")
        disk.files = [final]
        XCTAssertEqual(tracker.apply(paths: [bundle, "\(bundle)/Info.plist"], stat: disk.stat, now: t0 + 6),
                       [.init(kind: .ended, path: bundle), .init(kind: .finished, path: final)])
    }

    func testFirefoxPlaceholderSequence() {
        var tracker = DownloadTracker(folders: [dl])
        var disk = Disk()
        let part = "\(dl)/a.zip.part", final = "\(dl)/a.zip"
        disk.files = [final, part]   // Firefox creates an empty placeholder with the final name
        disk.empty = [final]
        XCTAssertEqual(tracker.apply(paths: [final, part], stat: disk.stat, now: t0).map(\.kind), [.started])
        disk.files = [final]
        disk.empty = []
        XCTAssertEqual(tracker.apply(paths: [part, final], stat: disk.stat, now: t0 + 20).map(\.kind),
                       [.ended, .finished])
    }

    func testCancelledAndCopiedFilesAreNoDownload() {
        var tracker = DownloadTracker(folders: [dl])
        var disk = Disk(files: ["\(dl)/b.iso.crdownload"])
        _ = tracker.apply(paths: ["\(dl)/b.iso.crdownload"], stat: disk.stat, now: t0)
        disk.files = []
        XCTAssertEqual(tracker.apply(paths: ["\(dl)/b.iso.crdownload"], stat: disk.stat, now: t0 + 3).map(\.kind),
                       [.ended], "cancelled: no finished notice")
        disk.files = ["\(dl)/b.iso"]
        XCTAssertEqual(tracker.apply(paths: ["\(dl)/b.iso"], stat: disk.stat, now: t0 + 3 + DownloadTracker.finishGrace + 1),
                       [], "a file of that name much later is not this download")

        disk.files = ["\(dl)/copied.txt", "\(dl)/.DS_Store"]
        XCTAssertEqual(tracker.apply(paths: ["\(dl)/copied.txt", "\(dl)/.DS_Store"], stat: disk.stat, now: t0 + 60),
                       [], "a file copied or unzipped in is not a download")
        XCTAssertEqual(tracker.apply(paths: ["/elsewhere/x.crdownload"], stat: { _ in FileStat(size: 1) }, now: t0 + 61), [],
                       "outside the watched folders")
    }

    func testStaleDownloadIsDropped() {
        var tracker = DownloadTracker(folders: [dl])
        let p = "\(dl)/stuck.bin.crdownload"
        _ = tracker.apply(paths: [p], stat: { _ in FileStat(size: 1) }, now: t0)
        XCTAssertEqual(tracker.nextStaleCheck, t0 + DownloadTracker.staleAfter)
        XCTAssertEqual(tracker.pruneStale(now: t0 + 60), [])
        _ = tracker.apply(paths: [p], stat: { _ in FileStat(size: 1) }, now: t0 + 60)   // still being written
        XCTAssertEqual(tracker.pruneStale(now: t0 + DownloadTracker.staleAfter + 1), [], "seen since")
        XCTAssertEqual(tracker.pruneStale(now: t0 + 60 + DownloadTracker.staleAfter).map(\.kind), [.ended],
                       "no writes for 10 minutes: no longer shown")
        XCTAssertNil(tracker.nextStaleCheck)
    }

    func testFirefoxCancelLeavesNoNotice() {
        var tracker = DownloadTracker(folders: [dl])
        var disk = Disk()
        let part = "\(dl)/a.zip.part", final = "\(dl)/a.zip"
        disk.files = [final, part]
        disk.empty = [final]
        _ = tracker.apply(paths: [final, part], stat: disk.stat, now: t0)
        disk.files = [final]   // cancel: the .part goes first, the empty placeholder a batch later
        XCTAssertEqual(tracker.apply(paths: [part], stat: disk.stat, now: t0 + 2).map(\.kind), [.ended],
                       "an empty file is never a finished download")
        disk.files = []
        XCTAssertEqual(tracker.apply(paths: [final], stat: disk.stat, now: t0 + 3), [])
    }

    func testHugeBatchFollowsOnlyKnownDownloads() {
        var tracker = DownloadTracker(folders: [dl])
        var disk = Disk()
        let temp = "\(dl)/big.iso.crdownload", final = "\(dl)/big.iso"
        disk.files = [temp]
        _ = tracker.apply(paths: [temp], stat: disk.stat, now: t0)
        let unzipped = (0..<600).map { "\(dl)/file\($0).txt" } + (0..<5).map { "\(dl)/x\($0).crdownload" }
        disk.files = Set(unzipped).union([final])
        var stats = 0
        let events = tracker.apply(paths: unzipped + [temp, final], stat: { p in stats += 1; return disk.stat(p) },
                                   now: t0 + 5)
        XCTAssertEqual(events.map(\.kind), [.ended, .finished], "the known download still finishes")
        XCTAssertLessThanOrEqual(stats, 4, "the 600 other names are not stat'ed")
        XCTAssertTrue(tracker.active.isEmpty, "unknown in-progress names in a huge batch are skipped")
        XCTAssertLessThanOrEqual(tracker.pathsToStat(unzipped).count, 0 + 2)
    }

    func testEntriesAreUniqueAndCapped() {
        let tracker = DownloadTracker(folders: [dl])
        XCTAssertEqual(tracker.entries(["\(dl)/a", "\(dl)/a", "\(dl)/b.download/x", "\(dl)/b.download/y"]),
                       ["\(dl)/a", "\(dl)/b.download"])
        XCTAssertEqual(tracker.entries((0...DownloadTracker.maxBatchEntries).map { "\(dl)/f\($0)" }), [],
                       "over the cap with nothing in progress: nothing")
        XCTAssertEqual(Set(tracker.pathsToStat(["\(dl)/r.pdf.crdownload"])),
                       ["\(dl)/r.pdf.crdownload", "\(dl)/r.pdf"], "the final name too")
    }

    // MARK: - Second download folder

    func testWatchFolderPolicy() {
        let home = "/Users/me"
        let allowed = ["/Users/me/Downloads/Browser", "/Users/me/Incoming", "/Users/me/Pictures/Saved",
                       "/Users/Shared/Downloads", "/opt/downloads", "/private/tmp/in",
                       "/System/Volumes/Data/Users/me/Incoming"]
        for p in allowed { XCTAssertEqual(WatchFolderPolicy.check(p, home: home), .allowed, p) }
        let rejected = ["/Users/me/Desktop", "/Users/me/Desktop/In", "/Users/me/Documents/x", "/users/me/DOCUMENTS",
                        "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/In", "/Users/me/Library/Containers/x",
                        "/Volumes/USB/In", "/Volumes", "/Network/Servers/nas/in", "/net/nas/in",
                        "/Users/other/Downloads", "/System/Volumes/Data/Users/me/Desktop/x", "/", "/Users/me",
                        "/Users/me/", "relative/path"]
        for p in rejected {
            guard case .rejected(let why) = WatchFolderPolicy.check(p, home: home) else {
                XCTFail("\(p) should be rejected")
                continue
            }
            XCTAssertFalse(why.isEmpty, p)
        }
    }

    func testWatchFolderPolicyNormalizesAndRefusesRootsAndAncestors() {
        let home = "/Users/me"
        func rejected(_ p: String) -> Bool {
            if case .rejected = WatchFolderPolicy.check(p, home: home) { return true }
            return false
        }
        // `.`, `..` and `//` cannot hide a protected place.
        XCTAssertTrue(rejected("/Users/me/Incoming/../Desktop"))
        XCTAssertTrue(rejected("/Users/me/./Documents//DL"))
        XCTAssertTrue(rejected("//Volumes/USB"))
        XCTAssertTrue(rejected("/Users/me/Incoming/../../other/x"), "another user's home")
        XCTAssertFalse(rejected("/Users/me/Desktop/../Incoming"), "resolves to an allowed folder")
        // Ancestors of home.
        for p in ["/Users", "/System/Volumes/Data", "/System/Volumes/Data/Users", "/System/Volumes"] {
            XCTAssertTrue(rejected(p), p)
        }
        // The roots of Pictures, Movies, Music, but not their subfolders.
        for p in ["/Users/me/Pictures", "/Users/me/Movies/", "/Users/me/music"] { XCTAssertTrue(rejected(p), p) }
        for p in ["/Users/me/Pictures/Saved", "/Users/me/Movies/In", "/Users/me/Music/DL"] {
            XCTAssertFalse(rejected(p), p)
        }
    }

    func testNestedDownloadFoldersMatchTheDeepest() {
        let folders = [dl, "\(dl)/Browser"]
        XCTAssertEqual(DownloadDetector.entry(path: "\(dl)/Browser/a.pdf", folders: folders), "\(dl)/Browser/a.pdf")
        XCTAssertEqual(DownloadDetector.entry(path: "\(dl)/b.pdf", folders: folders), "\(dl)/b.pdf")
        var tracker = DownloadTracker(folders: folders)
        var disk = Disk()
        let temp = "\(dl)/Browser/a.pdf.crdownload", final = "\(dl)/Browser/a.pdf"
        disk.files = [temp]
        XCTAssertEqual(tracker.apply(paths: [temp], stat: disk.stat, now: t0).map(\.kind), [.started])
        disk.files = [final]
        XCTAssertEqual(tracker.apply(paths: [temp, final], stat: disk.stat, now: t0 + 3).map(\.kind), [.ended, .finished],
                       "a second folder inside ~/Downloads works")
    }
}
