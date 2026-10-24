import Foundation

/// SplitMix64: a tiny, fast generator, fully deterministic for a seed. Every game engine
/// takes its randomness from one of these, so the same seed plays the same game (tests).
public struct SeededRNG: RandomNumberGenerator, Equatable, Sendable {
    public private(set) var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A value in `0..<n` (`n` > 0). Our own reduction, so results never depend on how the
    /// standard library maps a generator onto a range.
    public mutating func below(_ n: Int) -> Int {
        precondition(n > 0)
        return Int(next() % UInt64(n))
    }

    /// A value in `0..<1`.
    public mutating func unit() -> Double {
        Double(next() >> 11) / 9_007_199_254_740_992.0   // 2^53
    }
}

/// A grid direction. `dy` grows downwards (row 0 is the top).
public enum Direction: String, CaseIterable, Equatable, Sendable {
    case up, down, left, right

    public var opposite: Direction {
        switch self {
        case .up: .down
        case .down: .up
        case .left: .right
        case .right: .left
        }
    }

    public var dx: Int {
        switch self {
        case .left: -1
        case .right: 1
        case .up, .down: 0
        }
    }

    public var dy: Int {
        switch self {
        case .up: -1
        case .down: 1
        case .left, .right: 0
        }
    }
}

/// A grid cell: column `x`, row `y` (row 0 is the top).
public struct Point: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    public func moved(_ d: Direction) -> Point { Point(x: x + d.dx, y: y + d.dy) }
}
