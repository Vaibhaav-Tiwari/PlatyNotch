import Foundation

/// `memory.graph` requests and replies for the Memory tab's Graph view, and the text
/// it shows (legend, details, the VoiceOver list).
public enum MemoryGraphFormat {
    /// Nodes asked for: what stays readable in the panel (the core's default is 100).
    public static let maxNodes = 40

    public enum Range: String, CaseIterable, Sendable, Identifiable {
        case day, week, month

        public var id: String { rawValue }
        public var hours: Int {
            switch self {
            case .day: 24
            case .week: 168
            case .month: 720
            }
        }
        public var title: String {
            switch self {
            case .day: "24 h"
            case .week: "7 d"
            case .month: "30 d"
            }
        }
        public var spoken: String {
            switch self {
            case .day: "Last 24 hours"
            case .week: "Last 7 days"
            case .month: "Last 30 days"
            }
        }
    }

    public enum Reply: Sendable, Equatable {
        case graph(MemoryGraph)
        case memoryOff
        case failed(String)
    }

    public static func envelope(range: Range) throws -> Envelope {
        try Envelope.make(.memoryGraph, MemoryGraphQuery(hours: range.hours, maxNodes: maxNodes))
    }

    public static func parse(_ reply: Envelope) -> Reply {
        switch reply.type {
        case MessageType.memoryGraph.rawValue:
            guard let g = try? reply.decode(MemoryGraph.self) else {
                return reply.data == nil ? .graph(MemoryGraph(nodes: [], edges: [])) : .failed("Unreadable graph from the core.")
            }
            return .graph(drawable(g))
        case MessageType.error.rawValue:
            let message = (try? reply.decode(ErrorMsg.self))?.message ?? ""
            if message == MemoryFormat.offMessage { return .memoryOff }
            return .failed(message.isEmpty ? "The graph failed to load." : message)
        default:
            return .failed("Unexpected reply from the core.")
        }
    }

    /// Drops nodes of kinds this app does not know, edges that touch a missing node
    /// and duplicate node ids, so everything left can be drawn.
    public static func drawable(_ g: MemoryGraph) -> MemoryGraph {
        var seen = Set<String>()
        let nodes = g.nodes.filter { $0.nodeKind != nil && seen.insert($0.id).inserted }
        let edges = g.edges.filter { seen.contains($0.from) && seen.contains($0.to) && $0.from != $0.to }
        return MemoryGraph(nodes: nodes, edges: edges)
    }

    /// A node's neighbours, heaviest first (ties by label), each once.
    public static func neighbours(of id: String, in g: MemoryGraph) -> [GraphNode] {
        var ids = Set<String>()
        for e in g.edges {
            if e.from == id { ids.insert(e.to) } else if e.to == id { ids.insert(e.from) }
        }
        return g.nodes.filter { ids.contains($0.id) }.sorted {
            $0.weight != $1.weight ? $0.weight > $1.weight : label($0) < label($1)
        }
    }

    /// Distinct neighbours per node id.
    public static func connectionCounts(_ g: MemoryGraph) -> [String: Int] {
        var sets: [String: Set<String>] = [:]
        for e in g.edges {
            sets[e.from, default: []].insert(e.to)
            sets[e.to, default: []].insert(e.from)
        }
        var out: [String: Int] = [:]
        for n in g.nodes { out[n.id] = sets[n.id]?.count ?? 0 }
        return out
    }

    public static func kindName(_ kind: GraphNodeKind) -> String {
        switch kind {
        case .app: "App"
        case .thread: "Thread"
        case .site: "Site"
        case .loop: "Open loop"
        case .topic: "Topic"
        }
    }

    /// Labels are untrusted screen text for threads and loops: one line, hidden
    /// characters made visible, "Untitled" when empty.
    public static func label(_ node: GraphNode) -> String {
        MemoryFormat.title(node.label)
    }

    public static func connections(_ n: Int) -> String {
        n == 1 ? "1 connection" : "\(n) connections"
    }

    /// "Thread, Inbox, 3 connections" (VoiceOver list rows).
    public static func accessibilityLabel(_ node: GraphNode, connections n: Int) -> String {
        let kind = node.nodeKind.map(kindName) ?? "Item"
        return "\(kind), \(label(node)), \(connections(n))"
    }

    /// The detail line under the graph: up to `limit` neighbour labels, then "+n more".
    public static func detail(_ node: GraphNode, in g: MemoryGraph, limit: Int = 4) -> String {
        let near = neighbours(of: node.id, in: g)
        let kind = node.nodeKind.map(kindName) ?? "Item"
        var line = "\(kind) · \(connections(near.count))"
        guard !near.isEmpty else { return line }
        line += ": " + near.prefix(limit).map(label).joined(separator: ", ")
        if near.count > limit { line += ", +\(near.count - limit) more" }
        return line
    }

    /// The VoiceOver list: heaviest first, as the core sends them.
    public static func accessibleRows(_ g: MemoryGraph) -> [(id: String, label: String)] {
        let counts = connectionCounts(g)
        return g.nodes.map { ($0.id, accessibilityLabel($0, connections: counts[$0.id] ?? 0)) }
    }

    /// Node radius in points for a weight, relative to the heaviest node: 4...10.
    public static func radius(weight: Double, maxWeight: Double) -> Double {
        guard maxWeight > 0, weight > 0 else { return 4 }
        return 4 + 6 * min(weight / maxWeight, 1).squareRoot()
    }
}
