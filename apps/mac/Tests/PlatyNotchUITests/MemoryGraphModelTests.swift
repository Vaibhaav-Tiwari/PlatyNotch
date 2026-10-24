import Foundation
import os
import PlatyNotchKit
import XCTest
@testable import PlatyNotchUI

@MainActor
final class MemoryGraphModelTests: XCTestCase {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Requests seen by the fake core, recorded under a lock (the request closure is
    /// not on the main actor).
    final class Box: Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: [MemoryGraphQuery]())
        func record(_ q: MemoryGraphQuery) { lock.withLock { $0.append(q) } }
        var queries: [MemoryGraphQuery] { lock.withLock { $0 } }
    }

    private let graph = MemoryGraph(
        nodes: [GraphNode(id: "app:mail", kind: "app", label: "Mail", weight: 2),
                GraphNode(id: "t1", kind: "thread", label: "Inbox", weight: 2),
                GraphNode(id: "x", kind: "person", label: "Sam", weight: 9)],
        edges: [GraphEdge(from: "app:mail", to: "t1", kind: "in", weight: 2),
                GraphEdge(from: "x", to: "t1", kind: "knows", weight: 1)])

    private func model(_ box: Box) -> MemoryGraphModel {
        let graph = self.graph
        return MemoryGraphModel { env in
            box.record(try env.decode(MemoryGraphQuery.self))
            return try Envelope.make(.memoryGraph, id: env.id, graph)
        }
    }

    /// Nothing is asked until the view is shown (refresh); a range change asks again.
    func testFetchesOnlyWhenShownAndOnRangeChange() async {
        let box = Box()
        let m = model(box)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.requests, 0)
        XCTAssertTrue(box.queries.isEmpty)

        m.refresh()
        await waitUntil { if case .loaded = m.phase { true } else { false } }
        // Unknown kinds and their edges are dropped before drawing.
        XCTAssertEqual(m.phase, .loaded(MemoryGraphFormat.drawable(graph)))
        XCTAssertEqual(box.queries, [MemoryGraphQuery(hours: 168, maxNodes: MemoryGraphFormat.maxNodes)])

        m.range = .month
        await waitUntil { box.queries.count == 2 }
        XCTAssertEqual(box.queries.last?.hours, 720)
        m.range = .month   // unchanged: no request
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(box.queries.count, 2)
    }

    func testMemoryOffAndErrors() async {
        let off = MemoryGraphModel { env in try Envelope.make(.error, id: env.id, ErrorMsg(message: "memory is off")) }
        off.refresh()
        await waitUntil { off.phase == .memoryOff }
        XCTAssertEqual(off.phase, .memoryOff)

        let down = MemoryGraphModel { _ in throw CoreClientError.notConnected }
        down.refresh()
        await waitUntil { down.phase != .loading && down.phase != .idle }
        XCTAssertEqual(down.phase, .failed("Not connected to the core."))
    }

    func testPresetNeverAsksAndLayoutIsCached() {
        let m = MemoryGraphModel(preset: graph)
        m.refresh()
        XCTAssertEqual(m.requests, 0)
        guard case .loaded(let g) = m.phase else { return XCTFail("\(m.phase)") }
        let a = m.layout(g, aspect: 2.01)
        let b = m.layout(g, aspect: 1.99)   // same rounded shape: same layout
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, GraphLayout.compute(g, aspect: 2))
        // Several shapes stay cached (window resizes back and forth), up to the limit.
        for aspect in [1.0, 3.0, 4.0, 5.0, 6.0] { _ = m.layout(g, aspect: aspect) }
        XCTAssertEqual(m.layout(g, aspect: 6), GraphLayout.compute(g, aspect: 6))
        XCTAssertEqual(Set(a.positions.keys), ["app:mail", "t1"])
    }

    func testServicesShareOneGraphModelAndDoNotFetchOnInit() {
        let client = CoreClient(socketPath: "/nonexistent/notch.sock")
        let services = MemoryServices(client: client)
        XCTAssertEqual(services.graph.phase, .idle)
        XCTAssertEqual(services.graph.requests, 0)
    }
}
