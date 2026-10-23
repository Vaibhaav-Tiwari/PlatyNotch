import Foundation
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class MemoryModelsTests: XCTestCase {
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
        let defaults = UserDefaults(suiteName: "platynotch.tests.\(UUID().uuidString)")!
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
}
