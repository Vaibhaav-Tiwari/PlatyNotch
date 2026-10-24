import Foundation

/// Flappy in a short, wide world (`width` × `height` units, y grows downwards). Advanced
/// by `step(dt:)`. Touching a pipe, the floor or the ceiling ends it.
public struct Flappy: Equatable, Sendable {
    public static let width: Double = 320
    public static let height: Double = 140
    public static let birdX: Double = 64
    public static let birdRadius: Double = 6
    /// Units per second², downwards.
    public static let gravity: Double = 600
    /// The upward speed a flap sets (units per second).
    public static let flapVelocity: Double = -200
    public static let pipeSpeed: Double = 80
    public static let pipeWidth: Double = 26
    public static let gapHeight: Double = 52
    /// Distance between pipes.
    public static let pipeSpacing: Double = 130
    /// The longest step taken at once; longer `dt`s are split (stable collisions).
    public static let maxStep: Double = 1.0 / 60.0

    /// A pipe pair: a gap centred at `gapY`, `gapHeight` tall, its left edge at `x`.
    /// Nested (`Flappy.Pipe`): a top-level `Pipe` clashes with `Foundation.Pipe`.
    public struct Pipe: Equatable, Sendable {
        public var x: Double
        public var gapY: Double
        public var gapHeight: Double
        /// The bird has passed it (counted once).
        public var scored: Bool

        public init(x: Double, gapY: Double, gapHeight: Double = Flappy.gapHeight, scored: Bool = false) {
            self.x = x
            self.gapY = gapY
            self.gapHeight = gapHeight
            self.scored = scored
        }
    }

    public var birdY: Double
    /// Units per second; positive is down.
    public var velocity: Double = 0
    public var pipes: [Pipe]
    public var score = 0
    public var isOver = false
    private var rng: SeededRNG

    public init(seed: UInt64) {
        rng = SeededRNG(seed: seed)
        birdY = Self.height / 2
        pipes = []
        pipes.append(Pipe(x: Self.width + 40, gapY: randomGap()))
    }

    public mutating func flap() {
        guard !isOver else { return }
        velocity = Self.flapVelocity
    }

    public mutating func step(dt: Double) {
        var left = max(dt, 0)
        while left > 0, !isOver {
            let h = min(left, Self.maxStep)
            advance(h)
            left -= h
        }
    }

    private mutating func advance(_ dt: Double) {
        velocity += Self.gravity * dt
        birdY += velocity * dt
        let dx = Self.pipeSpeed * dt
        for i in pipes.indices { pipes[i].x -= dx }
        pipes.removeAll { $0.x + Self.pipeWidth < 0 }
        let lastX = pipes.last?.x ?? -Double.infinity
        if lastX < Self.width - Self.pipeSpacing {
            let gap = randomGap()
            pipes.append(Pipe(x: max(lastX + Self.pipeSpacing, Self.width), gapY: gap))
        }
        for i in pipes.indices where !pipes[i].scored && pipes[i].x + Self.pipeWidth < Self.birdX {
            pipes[i].scored = true
            score += 1
        }
        if hits() { isOver = true }
    }

    private func hits() -> Bool {
        let r = Self.birdRadius
        if birdY - r <= 0 || birdY + r >= Self.height { return true }
        for p in pipes {
            let overlapsX = Self.birdX + r > p.x && Self.birdX - r < p.x + Self.pipeWidth
            guard overlapsX else { continue }
            let top = p.gapY - p.gapHeight / 2
            let bottom = p.gapY + p.gapHeight / 2
            if birdY - r < top || birdY + r > bottom { return true }
        }
        return false
    }

    private mutating func randomGap() -> Double {
        let margin: Double = Self.gapHeight / 2 + 12
        let span: Double = Self.height - 2 * margin
        return margin + rng.unit() * span
    }
}
