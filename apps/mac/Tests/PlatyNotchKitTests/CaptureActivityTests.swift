import XCTest
@testable import PlatyNotchKit

final class CaptureDecisionTests: XCTestCase {
    let filter = CaptureFilter(excluded: ["com.example.secret"])
    let text = "Meeting notes: send the deck to Priya by Friday afternoon."

    private func decide(_ bundle: String?, _ outcome: AXReadOutcome, secure: Bool = false, last: Int? = nil) -> CaptureDecision {
        filter.decide(bundleID: bundle, secureInput: secure, outcome: outcome, lastHash: last)
    }

    func testSendsReadableText() {
        let w = AXWindowText(title: "Ideas", text: text)
        XCTAssertEqual(decide("com.apple.Notes", .text(w)), .send(w))
    }

    func testEverySkipHasItsReason() {
        let w = AXWindowText(title: "Ideas", text: text)
        XCTAssertEqual(decide("com.example.secret", .text(w)), .skip(.excludedApp))
        XCTAssertEqual(decide("com.1password.1password", .text(w)), .skip(.excludedApp))
        XCTAssertEqual(decide(nil, .text(w)), .skip(.excludedApp))
        XCTAssertEqual(decide("com.apple.Notes", .text(w), secure: true), .skip(.passwordField))
        XCTAssertEqual(decide("com.apple.Notes", .passwordField), .skip(.passwordField))
        XCTAssertEqual(decide("com.apple.Notes", .noWindow), .skip(.noText))
        XCTAssertEqual(decide("com.apple.Notes", .accessibilityUnavailable), .skip(.accessibilityUnavailable))
        XCTAssertEqual(decide("com.apple.systempreferences", .text(AXWindowText(title: "Passwords", text: text))),
                       .skip(.passwordField))
        XCTAssertEqual(decide("com.google.Chrome", .text(AXWindowText(title: "Docs - Incognito", text: text))),
                       .skip(.privateWindow))
        XCTAssertEqual(decide("com.apple.Safari", .text(AXWindowText(title: nil, text: text))), .skip(.privateWindow))
        XCTAssertEqual(decide("com.apple.Safari", .text(AXWindowText(title: "Page", text: text,
                                                                     document: "Private Browsing"))), .skip(.privateWindow))
        XCTAssertEqual(decide("com.apple.Notes", .text(AXWindowText(title: "Ideas", text: "  ok  "))), .skip(.noText))
        XCTAssertEqual(decide("com.apple.Notes", .text(w), last: CaptureFilter.hash(text)), .skip(.unchanged))
    }

    /// The core drops captures under 40 characters; the app sent 20-39 and counted
    /// them as captured although nothing was stored.
    func testMinimumMatchesTheCore() {
        XCTAssertEqual(CaptureFilter.minChars, 40)
        let short = AXWindowText(title: "Ideas", text: String(repeating: "a", count: 39))
        XCTAssertEqual(decide("com.apple.Notes", .text(short)), .skip(.noText))
        let enough = AXWindowText(title: "Ideas", text: String(repeating: "a", count: 40))
        XCTAssertEqual(decide("com.apple.Notes", .text(enough)), .send(enough))
    }
}

final class CaptureIdleTests: XCTestCase {
    func testIdleAfterTwoMinutesWithoutInput() {
        XCTAssertFalse(CaptureFilter.isIdle(secondsSinceInput: 0))
        XCTAssertFalse(CaptureFilter.isIdle(secondsSinceInput: 119))
        XCTAssertTrue(CaptureFilter.isIdle(secondsSinceInput: 120))
        var a = CaptureActivity()
        a.skipped(.idle, app: "Safari", at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(a.skipLine(now: Date(timeIntervalSince1970: 0)), "Skipped Safari just now: idle (no input for 2 minutes)")
    }
}

final class CaptureActivityTests: XCTestCase {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    let noon = Date(timeIntervalSince1970: 1_761_998_400)   // 2025-11-01 12:00 UTC

    func testCountsTodayAndResetsNextDay() {
        var a = CaptureActivity()
        XCTAssertEqual(a.captureLine(now: noon, calendar: calendar), "Nothing captured yet")
        a.captured(app: "Safari", at: noon, calendar: calendar)
        a.captured(app: "Notes", at: noon.addingTimeInterval(60), calendar: calendar)
        XCTAssertEqual(a.capturedToday(now: noon.addingTimeInterval(120), calendar: calendar), 2)
        XCTAssertEqual(a.captureLine(now: noon.addingTimeInterval(120), calendar: calendar),
                       "Last capture 1m ago from Notes · 2 today")
        let tomorrow = noon.addingTimeInterval(86_400)
        XCTAssertEqual(a.capturedToday(now: tomorrow, calendar: calendar), 0)
        a.captured(app: "Mail", at: tomorrow, calendar: calendar)
        XCTAssertEqual(a.capturedToday(now: tomorrow, calendar: calendar), 1)
    }

    func testSkipShownUntilTheNextCapture() {
        var a = CaptureActivity()
        a.captured(app: "Safari", at: noon, calendar: calendar)
        a.skipped(.noText, app: "Terminal", at: noon.addingTimeInterval(20))
        XCTAssertEqual(a.skipLine(now: noon.addingTimeInterval(20)), "Skipped Terminal just now: no readable text")
        a.captured(app: "Safari", at: noon.addingTimeInterval(40), calendar: calendar)
        XCTAssertNil(a.skipLine(now: noon.addingTimeInterval(40)))
    }

    func testRestoredCount() {
        let a = CaptureActivity(count: 7, countDay: calendar.startOfDay(for: noon))
        XCTAssertEqual(a.capturedToday(now: noon, calendar: calendar), 7)
        XCTAssertEqual(a.captureLine(now: noon, calendar: calendar), "7 today")
    }
}
