import Foundation

/// Flappy in a wide world measured in the original game's pixels: `height` (400) is the
/// sky above the ground, y grows downwards. Advanced by `step(dt:)`. Touching a pipe or
/// the ground ends it; the top of the sky only stops the bird (as in the original, where
/// the bird can fly off the top but the pipes still reach it).
///
/// The constants follow the original's feel, cross-checked against two open-source clones
/// (FlapPyBird, MIT; floppybird, Apache-2.0) and converted from per-frame to per-second
/// units: gravity 900 px/s², a flap sets 275 px/s upwards, falling tops out at 300 px/s,
/// a 100 px gap, 52 px pipes 185 px apart scrolling at 135 px/s, a 34 × 24 bird whose
/// hitbox is a forgiving circle. No code or art was taken from either.
public struct Flappy: Equatable, Sendable {
    /// The world is wide (the notch panel); the original's portrait screen is 288 wide.
    public static let width: Double = 870
    /// The sky, top to the ground line.
    public static let height: Double = 400
    /// Ground drawn below `height` (not part of the physics).
    public static let groundDepth: Double = 36
    public static let birdX: Double = 170
    /// The hitbox: a circle inside the 34 × 24 sprite (the clones test the sprite's pixels).
    public static let birdRadius: Double = 11
    /// Units per second², downwards.
    public static let gravity: Double = 900
    /// The upward speed a flap sets (units per second).
    public static let flapVelocity: Double = -275
    /// The fastest the bird falls (units per second).
    public static let maxFallSpeed: Double = 300
    public static let pipeSpeed: Double = 135
    public static let pipeWidth: Double = 52
    public static let gapHeight: Double = 100
    /// Distance between pipes' left edges (about 1.4 s at `pipeSpeed`).
    public static let pipeSpacing: Double = 185
    /// Where the first pipe starts: about three seconds away.
    public static let firstPipeX: Double = 560
    /// The longest step taken at once; longer `dt`s are split (stable collisions).
    public static let maxStep: Double = 1.0 / 60.0
    /// One wing beat (up, middle, down, middle).
    public static let wingPeriod: Double = 0.36

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

    /// The wing's drawn position.
    public enum Wing: Equatable, Sendable { case up, middle, down }

    public var birdY: Double
    /// Units per second; positive is down.
    public var velocity: Double = 0
    public var pipes: [Pipe]
    public var score = 0
    public var isOver = false
    /// Seconds played (the wing beat).
    public private(set) var time: Double = 0
    /// How far the world has scrolled (the ground's stripes).
    public private(set) var distance: Double = 0
    private var rng: SeededRNG

    public init(seed: UInt64) {
        rng = SeededRNG(seed: seed)
        birdY = Self.height / 2
        pipes = []
        pipes.append(Pipe(x: Self.firstPipeX, gapY: randomGap()))
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

    /// The wing at `time` seconds: a steady beat, like the original's three-frame flap.
    public static func wing(at time: Double) -> Wing {
        let phase = (time / wingPeriod).truncatingRemainder(dividingBy: 1)
        let p = phase < 0 ? phase + 1 : phase
        if p < 0.25 { return .up }
        if p < 0.5 || p >= 0.75 { return .middle }
        return .down
    }

    public var wing: Wing { Self.wing(at: time) }

    /// The bird's tilt in degrees (positive is nose down): nose up while rising, level
    /// near the top of a hop, then a dive as it falls, steepest at full fall speed.
    public static func tilt(velocity v: Double) -> Double {
        let noseUp: Double = -22
        let diveFrom: Double = 120
        guard v > diveFrom else { return noseUp }
        let t: Double = min(1, (v - diveFrom) / (maxFallSpeed - diveFrom))
        return noseUp + t * 92
    }

    private mutating func advance(_ dt: Double) {
        time += dt
        velocity = min(velocity + Self.gravity * dt, Self.maxFallSpeed)
        birdY += velocity * dt
        let r = Self.birdRadius
        if birdY < r {   // the top of the sky stops it; it never ends the game
            birdY = r
            velocity = max(velocity, 0)
        }
        let dx = Self.pipeSpeed * dt
        distance += dx
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
        if birdY + r >= Self.height { return true }
        for p in pipes {
            let overlapsX = Self.birdX + r > p.x && Self.birdX - r < p.x + Self.pipeWidth
            guard overlapsX else { continue }
            let top = p.gapY - p.gapHeight / 2
            let bottom = p.gapY + p.gapHeight / 2
            if birdY - r < top || birdY + r > bottom { return true }
        }
        return false
    }

    /// A gap centre whose gap lies between 20% and 80% of the sky (the clones' range).
    private mutating func randomGap() -> Double {
        let low: Double = Self.height * 0.2 + Self.gapHeight / 2
        let high: Double = Self.height * 0.8 - Self.gapHeight / 2
        return low + rng.unit() * (high - low)
    }
}
