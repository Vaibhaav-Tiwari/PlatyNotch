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

    func testKeepAwakeSessionExpiresAcrossClockJumps() {
        // The deadline is a wall-clock date: a Mac asleep past it is expired on wake.
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        let s = KeepAwakeSession(duration: .oneHour, now: t0)
        XCTAssertTrue(s.isExpired(at: t0.addingTimeInterval(5 * 3600)))
    }
}
