import Foundation

/// Platy Chase's rules: every number in one place, so it can be checked line by line
/// against the reference (Jamey Pittman, "The Pac-Man Dossier", Table A.1 and the
/// sections on speed, frightened mode, scatter/chase, the ghost house and bonus symbols).
/// Rules and numbers only: the maze, the art and the names are our own.
public enum ChaseRules {
    /// 100% speed: 75.75757625 arcade pixels per second, 8 pixels to a tile.
    public static let maxSpeed: Double = 75.75757625 / 8
    /// The arcade's frame: the engine advances in these.
    public static let frame: Double = 1.0 / 60.0

    // MARK: Scoring

    public static let dotPoints = 10
    public static let pelletPoints = 50
    /// Chasers eaten during one fright: 200, 400, 800, 1600.
    public static let chaserPoints = [200, 400, 800, 1600]
    public static let extraLifeAt = 10_000
    public static let startLives = 3

    // MARK: Feel

    /// The player stops one frame for a dot and three for a power pellet.
    public static let dotPauseFrames = 1
    public static let pelletPauseFrames = 3
    /// Cornering: a turn is taken this many arcade pixels (8 to a tile) before the tile's
    /// centre (pre-turn) or after it (post-turn), cutting the corner diagonally. Moving
    /// right or down: 3 before, 4 after; moving left or up: 4 before, 3 after.
    public static func cornerWindow(_ d: Direction) -> (pre: Double, post: Double) {
        switch d {
        case .right, .down: (3.0 / 8.0, 4.0 / 8.0)
        case .left, .up: (4.0 / 8.0, 3.0 / 8.0)
        }
    }

    /// Frightened chasers try a pseudo-random direction first, then the next ones
    /// clockwise. The generator restarts each level and after each lost life.
    public static let clockwise: [Direction] = [.up, .right, .down, .left]
    /// Bonus items appear after this many dots (power pellets included) in a level.
    public static let bonusAtDots = [70, 170]
    /// A bonus item stays between 9 and 10 seconds (seeded).
    public static let bonusTime: ClosedRange<Double> = 9...10

    // MARK: Pauses and sequences (seconds)

    public static let readyTime: Double = 2.0
    /// Everything freezes when a chaser is eaten (its points shown).
    public static let chaserEatenFreeze: Double = 1.0
    /// Caught: a one-second freeze, then the player's death animation.
    public static let deathFreeze: Double = 1.0
    public static let deathAnimation: Double = 1.5
    /// The cleared maze flashes before the next level.
    public static let levelClearTime: Double = 2.0
    /// One white-and-blue flash at the end of a fright (14 frames).
    public static let flashTime: Double = 14.0 / 60.0

    // MARK: Not in the reference tables (chosen)

    /// Eyes going home and chasers moving inside the house.
    public static let eyesSpeed: Double = 1.6
    public static let houseSpeed: Double = 0.5

    // MARK: Ghost house

    /// The global counter used after a life is lost: the ambusher leaves at 7 dots, the
    /// flanker at 17, and at 32 the shy one (if still inside) leaves and the counter stops.
    public static let globalRelease = [7, 17, 32]

    // MARK: Per-level tables (index 0 is level 1; the last entry repeats)

    /// Player normal and frightened speeds (fractions of `maxSpeed`). The dot-eating
    /// speeds (~71%, ~79%, ~87%) are the effect of the one-frame pause per dot.
    static let playerSpeed: [Double] = [0.80, 0.90, 0.90, 0.90] + Array(repeating: 1.00, count: 16) + [0.90]
    static let playerFrightSpeed: [Double] = [0.90, 0.95, 0.95, 0.95] + Array(repeating: 1.00, count: 16) + [0.90]
    static let chaserSpeed: [Double] = [0.75, 0.85, 0.85, 0.85] + Array(repeating: 0.95, count: 17)
    static let chaserFrightSpeed: [Double] = [0.50, 0.55, 0.55, 0.55] + Array(repeating: 0.60, count: 17)
    static let chaserTunnelSpeed: [Double] = [0.40, 0.45, 0.45, 0.45] + Array(repeating: 0.50, count: 17)
    /// Dots left when the direct chaser speeds up ("Elroy" 1 and 2).
    static let elroy1Dots: [Int] = [20, 30, 40, 40, 40, 50, 50, 50, 60, 60, 60, 80, 80, 80, 100, 100, 100, 100, 120]
    static let elroy2Dots: [Int] = [10, 15, 20, 20, 20, 25, 25, 25, 30, 30, 30, 40, 40, 40, 50, 50, 50, 50, 60]
    static let elroy1Speed: [Double] = [0.80, 0.90, 0.90, 0.90, 1.00]
    static let elroy2Speed: [Double] = [0.85, 0.95, 0.95, 0.95, 1.05]
    /// Frightened seconds and flashes, levels 1–19 (none from 19 on; 17 has none either).
    static let frightTime: [Double] = [6, 5, 4, 3, 2, 5, 2, 2, 1, 5, 2, 1, 1, 3, 1, 1, 0, 1, 0]
    static let frightFlashes: [Int] = [5, 5, 5, 5, 5, 5, 5, 5, 3, 5, 5, 3, 3, 5, 3, 3, 0, 3, 0]
    /// Scatter, chase, scatter, chase, scatter, chase, scatter (then chase for ever).
    static let schedule1: [Double] = [7, 20, 7, 20, 5, 20, 5]
    static let schedule2to4: [Double] = [7, 20, 7, 20, 5, 1033, 1.0 / 60.0]
    static let schedule5up: [Double] = [5, 20, 5, 20, 5, 1037, 1.0 / 60.0]
    /// Personal dot limits (ambusher, flanker, shy) for levels 1, 2 and 3+.
    static let houseDotLimits: [[Int]] = [[0, 30, 60], [0, 0, 50], [0, 0, 0]]

    /// The mode after `frames` of scatter/chase time: the schedule's stretches in turn,
    /// scatter first, chase for ever after the last.
    public static func mode(afterFrames frames: Int, schedule: [Double]) -> ChaseMode {
        var end = 0
        for (i, seconds) in schedule.enumerated() {
            end += Int((seconds * 60).rounded())
            if frames < end { return i % 2 == 0 ? .scatter : .chase }
        }
        return .chase
    }

    public static func level(_ n: Int) -> ChaseLevel {
        let level = max(n, 1)
        func pick<T>(_ table: [T]) -> T { table[min(level - 1, table.count - 1)] }
        let schedule: [Double]
        switch level {
        case 1: schedule = schedule1
        case 2...4: schedule = schedule2to4
        default: schedule = schedule5up
        }
        return ChaseLevel(number: level,
                          playerSpeed: pick(playerSpeed), playerFrightSpeed: pick(playerFrightSpeed),
                          chaserSpeed: pick(chaserSpeed), chaserFrightSpeed: pick(chaserFrightSpeed),
                          chaserTunnelSpeed: pick(chaserTunnelSpeed),
                          elroy1Dots: pick(elroy1Dots), elroy1Speed: pick(elroy1Speed),
                          elroy2Dots: pick(elroy2Dots), elroy2Speed: pick(elroy2Speed),
                          frightTime: pick(frightTime), frightFlashes: pick(frightFlashes),
                          schedule: schedule, bonus: ChaseBonus.forLevel(level),
                          houseDotLimits: pick(houseDotLimits),
                          dotTimerLimit: level >= 5 ? 3 : 4)
    }
}

/// One level's numbers (see `ChaseRules`).
public struct ChaseLevel: Equatable, Sendable {
    public let number: Int
    public let playerSpeed: Double
    public let playerFrightSpeed: Double
    public let chaserSpeed: Double
    public let chaserFrightSpeed: Double
    public let chaserTunnelSpeed: Double
    public let elroy1Dots: Int
    public let elroy1Speed: Double
    public let elroy2Dots: Int
    public let elroy2Speed: Double
    public let frightTime: Double
    public let frightFlashes: Int
    /// Scatter and chase in turn, starting with scatter; chase for ever after the last.
    public let schedule: [Double]
    public let bonus: ChaseBonus
    /// Ambusher, flanker, shy.
    public let houseDotLimits: [Int]
    /// Seconds without a dot before the next chaser is let out.
    public let dotTimerLimit: Double
}

/// The bonus items: our own pond snacks, worth the original's per-level points.
public enum ChaseBonus: Int, CaseIterable, Equatable, Sendable {
    case shrimp, snail, clam, crayfish, frog, dragonfly, lily, pearl

    public var points: Int {
        switch self {
        case .shrimp: 100
        case .snail: 300
        case .clam: 500
        case .crayfish: 700
        case .frog: 1000
        case .dragonfly: 2000
        case .lily: 3000
        case .pearl: 5000
        }
    }

    /// Levels 1, 2, 3–4, 5–6, 7–8, 9–10, 11–12, 13+.
    public static func forLevel(_ level: Int) -> ChaseBonus {
        switch max(level, 1) {
        case 1: .shrimp
        case 2: .snail
        case 3...4: .clam
        case 5...6: .crayfish
        case 7...8: .frog
        case 9...10: .dragonfly
        case 11...12: .lily
        default: .pearl
        }
    }
}
