import PlatyNotchKit
import XCTest

final class HeaderStatusTests: DefaultsTestCase {
    func testChargingShowsPercentAndWord() {
        let b = BatteryState(percent: 64, charging: true, pluggedIn: true, minutesRemaining: nil)
        XCTAssertEqual(HeaderBattery.badge(b), HeaderBadge(text: "64% charging", symbol: "bolt.fill", tone: .working))
    }

    func testLowBelowTwentyUnplugged() {
        let low = BatteryState(percent: 19, charging: false, pluggedIn: false, minutesRemaining: 40)
        XCTAssertEqual(HeaderBattery.badge(low), HeaderBadge(text: "19%", symbol: "battery.25", tone: .error))
        let twenty = BatteryState(percent: 20, charging: false, pluggedIn: false, minutesRemaining: 40)
        XCTAssertNil(HeaderBattery.badge(twenty))
        XCTAssertNil(HeaderBattery.badge(nil))
    }

    func testPluggedInNotChargingHidden() {
        XCTAssertNil(HeaderBattery.badge(BatteryState(percent: 100, charging: false, pluggedIn: true, minutesRemaining: nil)))
        XCTAssertNil(HeaderBattery.badge(BatteryState(percent: 15, charging: false, pluggedIn: true, minutesRemaining: nil)))
    }

    func testKeepAwakeRemaining() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let s = KeepAwakeSession(duration: .twoHours, now: t)
        XCTAssertEqual(KeepAwakeLabel.remaining(s, now: t.addingTimeInterval(40 * 60)), "1:20")
        let almost = KeepAwakeSession(duration: .thirtyMinutes, now: t)
        XCTAssertEqual(KeepAwakeLabel.remaining(almost, now: t.addingTimeInterval(30 * 60 - 59)), "0:01")
        XCTAssertNil(KeepAwakeLabel.remaining(KeepAwakeSession(duration: .untilOff, now: t), now: t))
        XCTAssertNil(KeepAwakeLabel.remaining(nil, now: t))
    }

    func testKeepAwakeExpiredAfterSleepShowsOff() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let s = KeepAwakeSession(duration: .thirtyMinutes, now: t)
        XCTAssertNil(KeepAwakeLabel.remaining(s, now: t.addingTimeInterval(3 * 3600)))
        XCTAssertNil(KeepAwakeLabel.remaining(s, now: t.addingTimeInterval(30 * 60)), "never 0:00")
    }

    /// 31 October 2025 is a Friday (the brief says 2026-10-31, which is a Saturday).
    func testDateAndWeather() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let locale = Locale(identifier: "en_US_POSIX")
        let noon = DateComponents(calendar: cal, year: 2025, month: 10, day: 31, hour: 12).date ?? Date()
        XCTAssertEqual(HeaderDate.text(now: noon, weather: "14° Clear", calendar: cal, locale: locale), "Fri 31 · 14° Clear")
        XCTAssertEqual(HeaderDate.text(now: noon, weather: nil, calendar: cal, locale: locale), "Fri 31")
        XCTAssertEqual(HeaderDate.text(now: noon, weather: "", calendar: cal, locale: locale), "Fri 31")
    }

    func testPreferredDurationDefaultsToTwoHours() {
        let d = defaults()
        XCTAssertEqual(KeepAwakeDuration.preferred(in: d), .twoHours)
        KeepAwakeDuration.oneHour.savePreferred(to: d)
        XCTAssertEqual(KeepAwakeDuration.preferred(in: d), .oneHour)
        d.set("junk", forKey: KeepAwakeDuration.preferenceKey)
        XCTAssertEqual(KeepAwakeDuration.preferred(in: d), .twoHours)
    }
}
