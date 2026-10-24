import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class MemoryModelsTests: DefaultsTestCase {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    final class Box: @unchecked Sendable { var queries: [String] = [] }

    private let hit = MemoryHit(threadID: "t1", title: "Deck", sourceApp: "Notes", snippet: "send the deck",
                                score: 1, at: Date(timeIntervalSince1970: 0))

    func testTypingIsDebouncedToOneSearch() async {
        let box = Box()
        let hit = self.hit
        let model = MemorySearchModel(debounce: .milliseconds(50)) { env in
            box.queries.append(try env.decode(MemorySearch.self).query)
            return try Envelope.make(.memoryResults, id: env.id, MemoryResults(hits: [hit]))
        }
        model.query = "d"
        model.query = "de"
        model.query = "deck "
        await waitUntil { model.phase == .results([hit]) }
        XCTAssertEqual(model.phase, .results([hit]))
        XCTAssertEqual(box.queries, ["deck"])
    }

    func testRefreshWithEmptyQueryAsksForRecent() async {
        let box = Box()
        let model = MemorySearchModel { env in
            box.queries.append(try env.decode(MemorySearch.self).query)
            return try Envelope.make(.memoryResults, id: env.id, MemoryResults(hits: []))
        }
        model.refresh()
        await waitUntil { model.phase == .results([]) }
        XCTAssertEqual(box.queries, [""])
    }

    func testMemoryOffAndErrors() async {
        let off = MemorySearchModel { env in try Envelope.make(.error, id: env.id, ErrorMsg(message: "memory is off")) }
        off.refresh()
        await waitUntil { off.phase == .memoryOff }
        XCTAssertEqual(off.phase, .memoryOff)

        let down = MemorySearchModel { _ in throw CoreClientError.notConnected }
        down.refresh()
        await waitUntil { down.phase != .loading && down.phase != .idle }
        XCTAssertEqual(down.phase, .failed("Not connected to the core."))
    }

    func testCaptureOffWhenMemoryDisabledAndPausePersists() {
        let defaults = self.defaults()
        let capture = CaptureService(send: { _ in }, defaults: defaults)
        capture.apply(CaptureSettings(enabled: false))
        XCTAssertEqual(capture.status, .off)
        XCTAssertFalse(capture.isCapturing)

        capture.pause(for: 3600)
        let until = try? XCTUnwrap(capture.pausedUntil)
        XCTAssertEqual(until?.timeIntervalSinceNow ?? 0, 3600, accuracy: 5)
        XCTAssertNotNil(CaptureService(send: { _ in }, defaults: defaults).pausedUntil)   // survives relaunch
        capture.resume()
        XCTAssertNil(capture.pausedUntil)
        XCTAssertEqual(capture.status, .off)   // memory still off
    }

    /// The recent list was fetched only when the tab appeared, so an open tab kept
    /// showing what was current when it opened.
    func testCaptureRefreshesRecentButNotATypedSearch() async {
        let box = Box()
        let model = MemorySearchModel(debounce: .milliseconds(10)) { env in
            box.queries.append(try env.decode(MemorySearch.self).query)
            return try Envelope.make(.memoryResults, id: env.id, MemoryResults(hits: []))
        }
        model.captureArrived()
        await waitUntil { box.queries.count == 1 }
        XCTAssertEqual(box.queries, [""])
        model.query = "deck"
        await waitUntil { box.queries.count == 2 }
        model.captureArrived()
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(box.queries, ["", "deck"])
    }

    func testTodayCountSurvivesRelaunch() {
        let defaults = self.defaults()
        let today = Calendar.current.startOfDay(for: Date())
        defaults.set(5, forKey: CaptureService.todayCountKey)
        defaults.set(today.timeIntervalSince1970, forKey: CaptureService.todayDayKey)
        let capture = CaptureService(send: { _ in }, defaults: defaults)
        XCTAssertEqual(capture.activity.capturedToday(now: Date()), 5)
    }

    final class FakeAX: ManualAccessibilityAX, @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        var calls: [String] { lock.withLock { log } }
        func isSettable(pid: pid_t) -> Bool { true }
        func isOn(pid: pid_t) -> Bool { false }
        func set(_ on: Bool, pid: pid_t) { lock.withLock { log.append("\(on) \(pid)") } }
    }

    /// Capture turns Chromium/Electron accessibility on; pausing, memory off and quit
    /// turn it off again in every app it was turned on in.
    func testManualAccessibilityUndoneOnPauseStopAndQuit() async {
        let ax = FakeAX()
        let capture = CaptureService(send: { _ in }, defaults: defaults(), manualAX: ax)
        capture.enableManualAccessibility(pid: 42)
        capture.enableManualAccessibility(pid: 42)
        capture.pause(for: 60)
        await waitUntil { ax.calls.count == 2 }
        XCTAssertEqual(ax.calls, ["true 42", "false 42"])

        capture.resume()
        capture.apply(CaptureSettings(enabled: true))
        capture.enableManualAccessibility(pid: 7)
        capture.apply(CaptureSettings(enabled: false))
        await waitUntil { ax.calls.count == 4 }
        XCTAssertEqual(ax.calls.suffix(2), ["true 7", "false 7"])

        capture.enableManualAccessibility(pid: 9)
        capture.revertManualAccessibility(wait: true)
        XCTAssertEqual(ax.calls.suffix(2), ["true 9", "false 9"])
    }

    /// One app is undone when excluded; a quit app is forgotten without a set(false).
    func testManualAccessibilityUndoneForOneAppAndForgottenOnQuit() {
        let ax = FakeAX()
        let capture = CaptureService(send: { _ in }, defaults: defaults(), manualAX: ax)
        capture.enableManualAccessibility(pid: 1)
        capture.enableManualAccessibility(pid: 2)
        capture.revertManualAccessibility(pid: 1)
        capture.forgetManualAccessibility(pid: 2)
        capture.revertManualAccessibility(wait: true)   // drains the queue; nothing left to undo
        XCTAssertEqual(ax.calls, ["true 1", "true 2", "false 1"])
    }
}
