import Foundation

/// Snake on a wide, notch-shaped board. Advanced by `step` (the host calls it every
/// `GameSession.snakeStep`). Hitting a wall or itself ends the game; turning straight
/// back is ignored, also two quick turns between steps.
public struct Snake: Equatable, Sendable {
    /// Where the head starts (column); the body trails to its left, heading right.
    public static let startHeadX = 5

    public let width: Int
    public let height: Int
    /// Head first.
    public var body: [Point]
    public var food: Point
    public var isOver = false
    public var score = 0
    /// The direction of the last step (turns are checked against it, not against `next`).
    public private(set) var heading: Direction = .right
    /// The direction the next step takes.
    public private(set) var next: Direction = .right
    private var rng: SeededRNG

    public init(width: Int = 24, height: Int = 8, seed: UInt64) {
        self.width = max(width, Self.startHeadX + 2)
        self.height = max(height, 1)
        rng = SeededRNG(seed: seed)
        let row = self.height / 2
        body = (0..<3).map { Point(x: Self.startHeadX - $0, y: row) }
        food = Point(x: 0, y: 0)
        food = freeCell() ?? Point(x: 0, y: 0)
    }

    public mutating func turn(_ d: Direction) {
        guard !isOver, d != heading.opposite else { return }
        next = d
    }

    public mutating func step() {
        guard !isOver, let head = body.first else { return }
        heading = next
        let new = head.moved(heading)
        guard new.x >= 0, new.x < width, new.y >= 0, new.y < height else {
            isOver = true
            return
        }
        let eats = new == food
        // The tail moves away this step unless the snake grows, so the head may take its cell.
        let blocking = eats ? body : Array(body.dropLast())
        if blocking.contains(new) {
            isOver = true
            return
        }
        body.insert(new, at: 0)
        if eats {
            score += 1
            if let cell = freeCell() { food = cell } else { isOver = true }   // the board is full
        } else {
            body.removeLast()
        }
    }

    /// A random cell not on the snake; nil when there is none.
    private mutating func freeCell() -> Point? {
        let taken = Set(body)
        var free: [Point] = []
        free.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width where !taken.contains(Point(x: x, y: y)) { free.append(Point(x: x, y: y)) }
        }
        guard !free.isEmpty else { return nil }
        return free[rng.below(free.count)]
    }
}
