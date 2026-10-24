import Foundation
import XCTest
@testable import PlatyNotchKit

final class MemoryGraphTests: XCTestCase {
    private func node(_ id: String, _ kind: GraphNodeKind, _ label: String, _ w: Double = 1) -> GraphNode {
        GraphNode(id: id, kind: kind.rawValue, label: label, weight: w)
    }

    private var sample: MemoryGraph {
        var nodes = [node("app:mail", .app, "Mail", 6), node("app:safari", .app, "Safari", 5),
                     node("t1", .thread, "Inbox", 4), node("t2", .thread, "PR 12", 3),
                     node("t3", .thread, "Issues", 2), node("site:github.com", .site, "github.com", 5),
                     node("loop:l1", .loop, "Reply to Sam", 5)]
        var edges = [GraphEdge(from: "app:mail", to: "t1", kind: "in", weight: 4),
                     GraphEdge(from: "app:safari", to: "t2", kind: "in", weight: 3),
                     GraphEdge(from: "app:safari", to: "t3", kind: "in", weight: 2),
                     GraphEdge(from: "t2", to: "site:github.com", kind: "on", weight: 3),
                     GraphEdge(from: "t3", to: "site:github.com", kind: "on", weight: 2),
                     GraphEdge(from: "loop:l1", to: "t1", kind: "detected_in", weight: 5),
                     GraphEdge(from: "t1", to: "t2", kind: "together", weight: 3)]
        // A separate cluster.
        nodes.append(node("app:notes", .app, "Notes", 1))
        nodes.append(node("t4", .thread, "Old note", 1))
        edges.append(GraphEdge(from: "app:notes", to: "t4", kind: "in", weight: 1))
        return MemoryGraph(nodes: nodes, edges: edges)
    }

    // MARK: layout

    func testLayoutIsDeterministic() {
        let a = GraphLayout.compute(sample, aspect: 3, seed: 7)
        let b = GraphLayout.compute(sample, aspect: 3, seed: 7)
        XCTAssertEqual(a, b)
        // Input order does not matter: each start position is seeded by the node's id.
        var shuffled = sample
        shuffled.nodes.reverse()
        shuffled.edges.reverse()
        let c = GraphLayout.compute(shuffled, aspect: 3, seed: 7)
        for (id, p) in a.positions {
            XCTAssertEqual(p.x, c.positions[id]!.x, accuracy: 1e-6, id)
            XCTAssertEqual(p.y, c.positions[id]!.y, accuracy: 1e-6, id)
        }
        XCTAssertNotEqual(a, GraphLayout.compute(sample, aspect: 3, seed: 8))
    }

    func testLayoutStaysInsideThePaddedBox() {
        for aspect in [0.5, 1.0, 3.0] {
            let l = GraphLayout.compute(sample, aspect: aspect, seed: 1, padding: 0.1)
            XCTAssertEqual(l.positions.count, sample.nodes.count)
            for (id, p) in l.positions {
                XCTAssertTrue(p.x.isFinite && p.y.isFinite, id)
                XCTAssertGreaterThanOrEqual(p.x, 0.1 - 1e-9, id); XCTAssertLessThanOrEqual(p.x, aspect - 0.1 + 1e-9, id)
                XCTAssertGreaterThanOrEqual(p.y, 0.1 - 1e-9, id); XCTAssertLessThanOrEqual(p.y, 0.9 + 1e-9, id)
            }
        }
    }

    func testLinkedNodesSitCloserThanUnlinked() {
        let l = GraphLayout.compute(sample, aspect: 2, seed: 3)
        func d(_ a: String, _ b: String) -> Double {
            let p = l.positions[a]!, q = l.positions[b]!
            return ((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)).squareRoot()
        }
        XCTAssertLessThan(d("app:mail", "t1"), d("app:mail", "t4"))
        XCTAssertLessThan(d("app:notes", "t4"), d("app:notes", "t2"))
        // No two nodes on top of each other.
        let ids = Array(l.positions.keys)
        for i in ids.indices { for j in ids.indices where j > i { XCTAssertGreaterThan(d(ids[i], ids[j]), 0.02) } }
    }

    func testLayoutEdgeCases() {
        XCTAssertTrue(GraphLayout.compute(MemoryGraph(nodes: [], edges: [])).positions.isEmpty)
        let one = GraphLayout.compute(MemoryGraph(nodes: [node("a", .app, "A")], edges: []), aspect: 2)
        XCTAssertEqual(one.positions["a"], .init(x: 1, y: 0.5))
        // Two nodes and a self loop: still finite and apart.
        let two = GraphLayout.compute(MemoryGraph(nodes: [node("a", .app, "A"), node("b", .thread, "B")],
                                                  edges: [GraphEdge(from: "a", to: "a", kind: "in", weight: 1),
                                                          GraphEdge(from: "a", to: "b", kind: "in", weight: 1)]))
        XCTAssertNotEqual(two.positions["a"], two.positions["b"])
        XCTAssertEqual(GraphLayout.compute(sample, iterations: 0).positions.count, sample.nodes.count)
    }

    func testPointAndNearest() {
        let l = GraphLayout(positions: ["a": .init(x: 0.5, y: 0.5), "b": .init(x: 1.5, y: 0.5)], aspect: 2)
        XCTAssertEqual(l.point("b", width: 400, height: 100), .init(x: 300, y: 50))
        XCTAssertNil(l.point("zz", width: 400, height: 100))
        XCTAssertEqual(l.nearest(x: 296, y: 52, width: 400, height: 100, within: 8, order: ["a", "b"]), "b")
        XCTAssertNil(l.nearest(x: 200, y: 50, width: 400, height: 100, within: 8, order: ["a", "b"]))
    }

    // MARK: format

    func testEnvelopeAsksForTheRange() throws {
        for (range, hours) in [(MemoryGraphFormat.Range.day, 24), (.week, 168), (.month, 720)] {
            let env = try MemoryGraphFormat.envelope(range: range)
            XCTAssertEqual(env.type, "memory.graph")
            XCTAssertEqual(try env.decode(MemoryGraphQuery.self), MemoryGraphQuery(hours: hours, maxNodes: MemoryGraphFormat.maxNodes))
        }
        XCTAssertEqual(MemoryGraphFormat.Range.allCases.map(\.title), ["24 h", "7 d", "30 d"])
    }

    func testParseReplies() throws {
        let g = sample
        XCTAssertEqual(MemoryGraphFormat.parse(try Envelope.make(.memoryGraph, id: "1", g)), .graph(g))
        XCTAssertEqual(MemoryGraphFormat.parse(Envelope.make(.memoryGraph, id: "1")), .graph(MemoryGraph(nodes: [], edges: [])))
        XCTAssertEqual(MemoryGraphFormat.parse(try Envelope.make(.error, ErrorMsg(message: "memory is off"))), .memoryOff)
        XCTAssertEqual(MemoryGraphFormat.parse(try Envelope.make(.error, ErrorMsg(message: "disk"))), .failed("disk"))
        XCTAssertEqual(MemoryGraphFormat.parse(try Envelope.make(.memoryResults, MemoryResults(hits: []))),
                       .failed("Unexpected reply from the core."))
        let bad = Envelope(type: "memory.graph", data: try RawJSON(encoding: ["nodes": 1]))
        XCTAssertEqual(MemoryGraphFormat.parse(bad), .failed("Unreadable graph from the core."))
    }

    func testDrawableDropsUnknownKindsAndDanglingEdges() {
        let g = MemoryGraph(nodes: [node("a", .app, "A"), GraphNode(id: "p", kind: "person", label: "Sam", weight: 9),
                                    node("a", .app, "dup"), node("t", .thread, "T")],
                            edges: [GraphEdge(from: "a", to: "t", kind: "in", weight: 1),
                                    GraphEdge(from: "p", to: "t", kind: "knows", weight: 1),
                                    GraphEdge(from: "t", to: "gone", kind: "on", weight: 1)])
        let d = MemoryGraphFormat.drawable(g)
        XCTAssertEqual(d.nodes.map(\.label), ["A", "T"])
        XCTAssertEqual(d.edges, [GraphEdge(from: "a", to: "t", kind: "in", weight: 1)])
    }

    func testConnectionsAndText() {
        let g = sample
        let counts = MemoryGraphFormat.connectionCounts(g)
        XCTAssertEqual(counts["t1"], 3)          // Mail, the loop, PR 12
        XCTAssertEqual(counts["site:github.com"], 2)
        XCTAssertEqual(MemoryGraphFormat.neighbours(of: "t1", in: g).map(\.label), ["Mail", "Reply to Sam", "PR 12"])
        let t1 = g.nodes[2]
        XCTAssertEqual(MemoryGraphFormat.detail(t1, in: g), "Thread · 3 connections: Mail, Reply to Sam, PR 12")
        XCTAssertEqual(MemoryGraphFormat.detail(t1, in: g, limit: 1), "Thread · 3 connections: Mail, +2 more")
        XCTAssertEqual(MemoryGraphFormat.accessibleRows(g).first?.label, "App, Mail, 1 connection")
        XCTAssertEqual(MemoryGraphFormat.accessibleRows(g).map(\.id), g.nodes.map(\.id))
        let loop = node("loop:x", .loop, "  ")
        XCTAssertEqual(MemoryGraphFormat.accessibilityLabel(loop, connections: 0), "Open loop, Untitled, 0 connections")
    }

    func testLabelsAreSanitised() {
        let n = node("t", .thread, "Inbox\u{202E}evil\nline")
        let l = MemoryGraphFormat.label(n)
        XCTAssertFalse(l.contains("\n"))
        XCTAssertFalse(l.unicodeScalars.contains("\u{202E}"))
    }

    func testShortLabelCutsBeforeSanitising() {
        XCTAssertEqual(MemoryGraphFormat.shortLabel(node("t", .thread, "Inbox"), max: 28), "Inbox")
        XCTAssertEqual(MemoryGraphFormat.shortLabel(node("t", .thread, "abcdefghij klm"), max: 10), "abcdefghij…")
        XCTAssertEqual(MemoryGraphFormat.shortLabel(node("t", .thread, "   "), max: 10), "Untitled")
        // A hidden character inside the cut is made visible whole, never half-escaped.
        let s = MemoryGraphFormat.shortLabel(node("t", .thread, "ab\u{202E}cdefghijklmnop"), max: 4)
        XCTAssertTrue(s.hasSuffix("…"))
        XCTAssertFalse(s.unicodeScalars.contains("\u{202E}"))
        XCTAssertEqual(s, MemoryFormat.title("ab\u{202E}c") + "…")
    }

    func testRadius() {
        XCTAssertEqual(MemoryGraphFormat.radius(weight: 9, maxWeight: 9), 10)
        XCTAssertEqual(MemoryGraphFormat.radius(weight: 0, maxWeight: 9), 4)
        XCTAssertEqual(MemoryGraphFormat.radius(weight: 1, maxWeight: 0), 4)
        XCTAssertEqual(MemoryGraphFormat.radius(weight: 20, maxWeight: 9), 10)
    }

    func testLayoutOfFortyNodesIsQuick() {
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        for i in 0..<40 {
            nodes.append(node("n\(i)", i % 5 == 0 ? .app : .thread, "N\(i)", Double(40 - i)))
            if i % 5 != 0 { edges.append(GraphEdge(from: "n\(i - i % 5)", to: "n\(i)", kind: "in", weight: 1)) }
        }
        let g = MemoryGraph(nodes: nodes, edges: edges)
        let start = Date()
        _ = GraphLayout.compute(g, aspect: 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)   // debug build; ~ms in release
    }
}
