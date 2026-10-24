import Foundation

/// The seven tetrominoes.
public enum Tetromino: Int, CaseIterable, Equatable, Sendable {
    case i, o, t, s, z, j, l

    /// The value a locked cell of this piece has on `Tetris.board` (0 is empty).
    public var cellValue: Int { rawValue + 1 }

    /// The size of the square box the piece rotates in.
    public var boxSize: Int {
        switch self {
        case .i, .o: 4
        default: 3
        }
    }

    /// Cells at rotation 0, in box coordinates (row 0 at the top).
    var baseCells: [Point] {
        switch self {
        case .i: [Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1), Point(x: 3, y: 1)]
        case .o: [Point(x: 1, y: 0), Point(x: 2, y: 0), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .t: [Point(x: 1, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .s: [Point(x: 1, y: 0), Point(x: 2, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1)]
        case .z: [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .j: [Point(x: 0, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        case .l: [Point(x: 2, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 2, y: 1)]
        }
    }

    /// Cells at `rotation` (0…3, clockwise) in box coordinates. The O never turns.
    public func cells(rotation: Int) -> [Point] {
        guard self != .o else { return baseCells }
        let n = boxSize
        var points = baseCells
        for _ in 0..<(((rotation % 4) + 4) % 4) {
            points = points.map { Point(x: n - 1 - $0.y, y: $0.x) }
        }
        return points
    }
}

/// A falling piece: its kind, rotation (0…3) and box position on the board.
public struct TetrisPiece: Equatable, Sendable {
    public var kind: Tetromino
    public var rotation: Int
    public var x: Int
    public var y: Int

    public init(kind: Tetromino, rotation: Int = 0, x: Int, y: Int) {
        self.kind = kind
        self.rotation = rotation
        self.x = x
        self.y = y
    }

    /// Board cells it covers.
    public var cells: [Point] {
        kind.cells(rotation: rotation).map { Point(x: $0.x + x, y: $0.y + y) }
    }
}

public enum TetrisInput: Equatable, Sendable {
    case left, right, rotate, softDrop, hardDrop
}

/// Tetris with a 7-bag randomizer, simple wall kicks and classic line scores. Advanced by
/// `tick` (gravity, every `tickInterval`) and `apply` (the player's input).
public struct Tetris: Equatable, Sendable {
    /// Points for clearing 1, 2, 3 or 4 lines at once.
    public static let lineScores = [0, 100, 300, 500, 800]
    /// Horizontal offsets tried, in order, when a rotation does not fit.
    public static let kicks = [0, -1, 1, -2, 2]
    public static let slowestTick: Double = 0.8
    public static let fastestTick: Double = 0.1

    public let width: Int
    public let height: Int
    /// `height` rows of `width` cells; 0 is empty, else the `cellValue` of the piece locked there.
    /// The falling piece is not on it (`current`).
    public var board: [[Int]]
    public private(set) var current: TetrisPiece
    /// The next pieces, at least one full bag ahead.
    public private(set) var queue: [Tetromino]
    public var linesCleared = 0
    public var score = 0
    public var isOver = false
    private var rng: SeededRNG

    public init(width: Int = 10, height: Int = 20, seed: UInt64) {
        self.width = max(width, 4)
        self.height = max(height, 4)
        board = Array(repeating: Array(repeating: 0, count: self.width), count: self.height)
        rng = SeededRNG(seed: seed)
        queue = []
        current = TetrisPiece(kind: .o, x: 0, y: 0)
        refillQueue()
        spawn()
    }

    /// Test seam (C30): a given board, falling piece and queue (refilled from `seed` as it runs low).
    public init(board: [[Int]], piece: TetrisPiece, queue: [Tetromino], seed: UInt64 = 0) {
        height = board.count
        width = board.first?.count ?? 0
        self.board = board
        current = piece
        self.queue = queue
        rng = SeededRNG(seed: seed)
        refillQueue()
    }

    /// Seconds between gravity ticks: faster every 10 lines.
    public var tickInterval: Double {
        let level = Double(linesCleared / 10)
        return max(Self.fastestTick, Self.slowestTick - 0.07 * level)
    }

    public mutating func apply(_ input: TetrisInput) {
        guard !isOver else { return }
        switch input {
        case .left: _ = shift(dx: -1, dy: 0)
        case .right: _ = shift(dx: 1, dy: 0)
        case .softDrop: if !shift(dx: 0, dy: 1) { lock() }
        case .hardDrop:
            while shift(dx: 0, dy: 1) {}
            lock()
        case .rotate: rotate()
        }
    }

    /// Gravity: down one row, or lock where it is.
    public mutating func tick() {
        guard !isOver else { return }
        if !shift(dx: 0, dy: 1) { lock() }
    }

    // MARK: - Moves

    private func fits(_ p: TetrisPiece) -> Bool {
        p.cells.allSatisfy { c in
            c.x >= 0 && c.x < width && c.y >= 0 && c.y < height && board[c.y][c.x] == 0
        }
    }

    private mutating func shift(dx: Int, dy: Int) -> Bool {
        var p = current
        p.x += dx
        p.y += dy
        guard fits(p) else { return false }
        current = p
        return true
    }

    private mutating func rotate() {
        for dx in Self.kicks {
            var p = current
            p.rotation = (p.rotation + 1) % 4
            p.x += dx
            if fits(p) {
                current = p
                return
            }
        }
    }

    private mutating func lock() {
        for c in current.cells where c.y >= 0 && c.y < height && c.x >= 0 && c.x < width {
            board[c.y][c.x] = current.kind.cellValue
        }
        let kept = board.filter { row in row.contains(0) }
        let cleared = height - kept.count
        if cleared > 0 {
            let empty = Array(repeating: Array(repeating: 0, count: width), count: cleared)
            board = empty + kept
            linesCleared += cleared
            score += Self.lineScores[min(cleared, 4)]
        }
        spawn()
    }

    private mutating func spawn() {
        refillQueue()
        let kind = queue.removeFirst()
        refillQueue()
        current = TetrisPiece(kind: kind, x: (width - kind.boxSize) / 2, y: 0)
        if !fits(current) { isOver = true }
    }

    /// Keeps at least a full bag queued: each bag is all seven pieces, shuffled.
    private mutating func refillQueue() {
        while queue.count < Tetromino.allCases.count {
            var bag = Tetromino.allCases
            var i = bag.count - 1
            while i > 0 {
                bag.swapAt(i, rng.below(i + 1))
                i -= 1
            }
            queue += bag
        }
    }
}
