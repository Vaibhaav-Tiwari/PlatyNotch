import Foundation

/// A force-directed (Fruchterman–Reingold) layout of the memory graph, computed once:
/// seeded start positions, a fixed number of iterations and a linear cooling schedule,
/// so the same graph always lands in the same place and nothing moves afterwards.
/// Positions are in a box `aspect` wide and 1 high, with `padding` kept clear.
public struct GraphLayout: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public static let iterations = 300

    /// By node id.
    public let positions: [String: Point]
    public let aspect: Double

    public init(positions: [String: Point], aspect: Double) {
        self.positions = positions; self.aspect = aspect
    }

    /// `aspect` is width / height (clamped to 0.25...8); `padding` is in box units.
    public static func compute(_ graph: MemoryGraph, aspect: Double = 1, seed: UInt64 = 1,
                               iterations: Int = GraphLayout.iterations, padding: Double = 0.08) -> GraphLayout {
        let w = min(max(aspect, 0.25), 8)
        // Sorted ids and springs: the sums run in one order whatever order the core sent.
        let ids = Array(Set(graph.nodes.map(\.id))).sorted()
        let n = ids.count
        guard n > 0 else { return GraphLayout(positions: [:], aspect: w) }
        if n == 1 { return GraphLayout(positions: [ids[0]: Point(x: w / 2, y: 0.5)], aspect: w) }

        var index: [String: Int] = [:]
        for (i, id) in ids.enumerated() { index[id] = i }
        var springs: [(Int, Int, Double)] = []
        for e in graph.edges {
            guard let a = index[e.from], let b = index[e.to], a != b else { continue }
            springs.append((min(a, b), max(a, b), min(1 + log(max(e.weight, 1)), 3)))
        }
        springs.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }

        // Start: each node's own seeded spot, so adding a node does not move the others' start.
        var x = [Double](repeating: 0, count: n)
        var y = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var rng = SplitMix64(seed: seed ^ fnv1a(ids[i]))
            x[i] = rng.unit() * w
            y[i] = rng.unit()
        }

        let k = (w / Double(n)).squareRoot() * 0.9
        let k2 = k * k
        let t0 = w / 10
        let steps = max(iterations, 1)
        var dx = [Double](repeating: 0, count: n)
        var dy = [Double](repeating: 0, count: n)
        for step in 0..<steps {
            for i in 0..<n { dx[i] = 0; dy[i] = 0 }
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var ddx = x[i] - x[j]
                    var ddy = y[i] - y[j]
                    var d2 = ddx * ddx + ddy * ddy
                    if d2 < 1e-9 {   // coincident: a fixed nudge, never a random one
                        ddx = 1e-3 * Double(i - j); ddy = 1e-3; d2 = ddx * ddx + ddy * ddy
                    }
                    let f = k2 / d2   // k²/d, divided by d again to scale the unit vector
                    dx[i] += ddx * f; dy[i] += ddy * f
                    dx[j] -= ddx * f; dy[j] -= ddy * f
                }
            }
            for (a, b, s) in springs {
                let ddx = x[a] - x[b]
                let ddy = y[a] - y[b]
                let d = (ddx * ddx + ddy * ddy).squareRoot()
                guard d > 1e-9 else { continue }
                let f = d * s / k   // d²/k, over d for the unit vector
                dx[a] -= ddx * f; dy[a] -= ddy * f
                dx[b] += ddx * f; dy[b] += ddy * f
            }
            // Gentle gravity keeps separate clusters on screen.
            for i in 0..<n {
                dx[i] += (w / 2 - x[i]) * 0.05 / k
                dy[i] += (0.5 - y[i]) * 0.05 / k
            }
            let t = t0 * (1 - Double(step) / Double(steps))
            for i in 0..<n {
                let len = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
                guard len > 0 else { continue }
                let move = min(len, t)
                x[i] = min(max(x[i] + dx[i] / len * move, 0), w)
                y[i] = min(max(y[i] + dy[i] / len * move, 0), 1)
            }
        }
        return GraphLayout(positions: fit(ids: ids, x: x, y: y, width: w, padding: padding), aspect: w)
    }

    /// Scales the result to fill the box inside `padding`, keeping its proportions.
    private static func fit(ids: [String], x: [Double], y: [Double], width w: Double, padding: Double) -> [String: Point] {
        let minX = x.min() ?? 0, maxX = x.max() ?? 0
        let minY = y.min() ?? 0, maxY = y.max() ?? 0
        let spanX = maxX - minX, spanY = maxY - minY
        let pad = min(max(padding, 0), 0.4)
        let availX = w - 2 * pad, availY = 1 - 2 * pad
        var scale = 1.0
        if spanX > 1e-9 { scale = availX / spanX }
        if spanY > 1e-9 { scale = min(scale, availY / spanY) }
        if spanX <= 1e-9, spanY <= 1e-9 { scale = 0 }
        let offX = (w - spanX * scale) / 2, offY = (1 - spanY * scale) / 2
        var out: [String: Point] = [:]
        for i in ids.indices {
            out[ids[i]] = Point(x: offX + (x[i] - minX) * scale, y: offY + (y[i] - minY) * scale)
        }
        return out
    }

    /// The node position in a `width` × `height` view.
    public func point(_ id: String, width: Double, height: Double) -> Point? {
        guard let p = positions[id] else { return nil }
        return Point(x: p.x / aspect * width, y: p.y * height)
    }

    /// The node nearest (x, y) in a `width` × `height` view, if within `within` points;
    /// ties go to the earlier id in `order` (the heavier node).
    public func nearest(x: Double, y: Double, width: Double, height: Double, within: Double,
                        order: [String]) -> String? {
        var best: String?
        var bestD = within * within
        for id in order {
            guard let p = point(id, width: width, height: height) else { continue }
            let d = (p.x - x) * (p.x - x) + (p.y - y) * (p.y - y)
            if d <= bestD, best == nil || d < bestD { best = id; bestD = d }
        }
        return best
    }
}

/// FNV-1a over the UTF-8 bytes: a stable hash (Swift's `Hasher` is seeded per process).
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01b3
    }
    return h
}

/// A tiny deterministic generator for the start positions.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
