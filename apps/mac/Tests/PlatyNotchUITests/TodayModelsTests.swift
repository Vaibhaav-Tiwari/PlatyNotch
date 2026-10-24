import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class TodayModelsTests: DefaultsTestCase {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private let loop = Loop(id: "L1", title: "Send the deck", kind: "promise", status: "open",
                            detectedAt: Date(timeIntervalSince1970: 0))

    func testLoopDoneSendsResolvedAndHidesOnAck() async throws {
        final class Box: @unchecked Sendable { var sent: [Envelope] = [] }
        let box = Box()
        let actions = LoopActions { env in
            box.sent.append(env)
            return Envelope.make(.loopSetStatus, id: env.id)
        }
        actions.sync(open: [loop])
        actions.set(loop, .resolved)
        XCTAssertTrue(actions.pending.contains("L1"))
        await waitUntil { actions.hidden.contains("L1") }
        XCTAssertFalse(actions.pending.contains("L1"))
        XCTAssertNil(actions.errors["L1"])
        XCTAssertEqual(try box.sent.first?.decode(LoopSetStatus.self), LoopSetStatus(id: "L1", status: "resolved"))
        // loops.updated without it: forget; a reopened loop would show again
        actions.sync(open: [])
        XCTAssertTrue(actions.hidden.isEmpty)
    }

    func testAckAfterLoopsUpdatedDoesNotHideAReopenedLoop() async {
        let actions = LoopActions { env in Envelope.make(.loopSetStatus, id: env.id) }
        actions.sync(open: [loop])
        actions.set(loop, .resolved)
        actions.sync(open: [])   // loops.updated arrives before the ack
        await waitUntil { !actions.pending.contains("L1") }
        XCTAssertFalse(actions.hidden.contains("L1"))
    }

    func testLoopErrorShownInline() async {
        let actions = LoopActions { env in try Envelope.make(.error, id: env.id, ErrorMsg(message: "memory is off")) }
        actions.set(loop, .dismissed)
        await waitUntil { actions.errors["L1"] != nil }
        XCTAssertEqual(actions.errors["L1"], "memory is off")
        XCTAssertFalse(actions.hidden.contains("L1"))

        let failing = LoopActions { _ in throw CoreClientError.timeout }
        failing.set(loop, .resolved)
        await waitUntil { failing.errors["L1"] != nil }
        XCTAssertEqual(failing.errors["L1"], "The core did not answer. Try again.")
    }

    func testFocusPersistsAndHoldsWhileRunning() {
        let defaults = self.defaults()
        let now = Date()
        let focus = FocusModel(defaults: defaults)
        XCTAssertFalse(focus.focusActive)
        focus.start(minutes: 25, now: now)
        XCTAssertTrue(focus.focusActive)
        XCTAssertNotNil(defaults.object(forKey: FocusModel.untilKey))

        let relaunched = FocusModel(defaults: defaults)   // survives relaunch
        XCTAssertEqual(relaunched.timer, focus.timer)
        XCTAssertTrue(relaunched.focusActive)

        relaunched.pause()
        XCTAssertFalse(relaunched.focusActive)
        XCTAssertNil(defaults.object(forKey: FocusModel.untilKey))
        relaunched.stop()
        XCTAssertNil(FocusModel(defaults: defaults).timer)
    }

    /// Final review C5: turning the Focus widget off ends a running session (no focus
    /// timer while focus is off); quitting (stop) keeps it.
    func testDisablingFocusWidgetStopsTheSession() {
        let focus = FocusModel(defaults: self.defaults())
        let widget = FocusWidget(focus: focus)
        focus.start(minutes: 25)
        widget.stop()
        XCTAssertTrue(focus.focusActive, "quit keeps the session")
        widget.disabled()
        XCTAssertNil(focus.timer)
        XCTAssertFalse(focus.focusActive)
    }

    func testFinishedFocusIsNotActive() {
        let defaults = self.defaults()
        var finished = 0
        let focus = FocusModel(defaults: defaults, onFinish: { finished += 1 })
        focus.start(minutes: 25, now: Date().addingTimeInterval(-26 * 60))   // already over
        XCTAssertFalse(focus.focusActive)
        XCTAssertTrue(focus.timer?.isDone ?? false)
        XCTAssertEqual(finished, 0)   // never active, so no chime
    }

    /// Opt-in: `PLATYNOTCH_MEDIAREMOTE_DIR=<out of scripts/fetch-mediaremote-adapter.sh> swift test`.
    func testAdapterStreamProducesUpdates() async throws {
        guard ProcessInfo.processInfo.environment["PLATYNOTCH_MEDIAREMOTE_DIR"] != nil, let files = AdapterFiles.locate()
        else { throw XCTSkip("set PLATYNOTCH_MEDIAREMOTE_DIR to a built mediaremote-adapter") }
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var updates = 0
            var last: NowPlayingInfo?
        }
        let seen = Seen()
        let stream = AdapterStream(files: files, onUpdate: { info in
            seen.lock.withLock { seen.updates += 1; seen.last = info }
        }, onExit: { _, _ in })
        try stream.start()
        for _ in 0..<100 where seen.lock.withLock({ seen.updates }) == 0 { try await Task.sleep(for: .milliseconds(50)) }
        stream.stop()
        XCTAssertGreaterThan(seen.lock.withLock { seen.updates }, 0)
        print("adapter now playing:", seen.lock.withLock { seen.last.map { "\($0.title) (\($0.bundleIdentifier)) playing=\($0.isPlaying)" } ?? "nothing" })
    }
}
