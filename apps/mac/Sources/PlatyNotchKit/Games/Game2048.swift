import Foundation

/// 2048 on a 4×4 grid. Advanced by `move` (turn-based: no frame loop). A move that changed
/// the grid spawns a 2 (90%) or a 4 (10%) in a random empty cell; one that did not, spawns
/// nothing. Over when no move can change the grid.
public struct Game2048: Equatable, Sendable {
    public static let size = 4
    public static let goal = 2048

    /// One tile's journey in a move, for the slide animation.
    public struct Slide: Equatable, Sendable {
        public var from: Point
        public var to: Point
        /// Its value before the move.
        public var value: Int
        /// It ends in a merge at `to` (both tiles of a merge have this set).
        public var merges: Bool

        public init(from: Point, to: Point, value: Int, merges: Bool) {
            self.from = from
            self.to = to
            self.value = value
            self.merges = merges
        }
    }

    /// What a move did, so the view can animate it: every tile on the grid before the move
    /// (still ones too, `from == to`), the cells that hold a merged tile after it, and the
    /// new tile. `serial` counts moves that changed the grid (a new value per move).
    public struct Move: Equatable, Sendable {
        public var serial: Int
        public var direction: Direction
        public var slides: [Slide]
        /// Cells holding a tile made by a merge, with its new value.
        public var merged: [Point]
        public var spawned: Point?
        public var spawnedValue: Int

        /// The grid before the move, rebuilt from `slides`.
        public var before: [[Int]] {
            var g = Array(repeating: Array(repeating: 0, count: Game2048.size), count: Game2048.size)
            for s in slides { g[s.from.y][s.from.x] = s.value }
            return g
        }
    }

    /// Rows, top first; 0 is empty.
    public private(set) var grid: [[Int]]
    public private(set) var score = 0
    public private(set) var isOver = false
    /// A 2048 tile was made (play may go on).
    public private(set) var won = false
    /// The last move that changed the grid; nil before the first.
    public private(set) var lastMove: Move?
    private var rng: SeededRNG

    public init(seed: UInt64) {
        grid = Array(repeating: Array(repeating: 0, count: Self.size), count: Self.size)
        rng = SeededRNG(seed: seed)
        spawn()
        spawn()
        refresh()
    }

    /// Test seam: a given grid (no tiles added).
    public init(grid: [[Int]], seed: UInt64) {
        self.grid = grid
        rng = SeededRNG(seed: seed)
        refresh()
    }

    /// Slides one line towards its start (index 0), merging equal neighbours once each:
    /// `[2, 2, 2, 2]` → `[4, 4, 0, 0]`, `[4, 4, 8, 0]` → `[8, 8, 0, 0]`. C30 test seam.
    public static func slide(row: [Int]) -> (row: [Int], gained: Int) {
        let r = track(row: row)
        return (r.row, r.gained)
    }

    /// `slide(row:)` that also says where each tile went: (from index, to index, merges).
    public static func track(row: [Int]) -> (row: [Int], gained: Int, moves: [(from: Int, to: Int, merges: Bool)]) {
        var tiles: [(index: Int, value: Int)] = []
        for (k, v) in row.enumerated() where v != 0 { tiles.append((k, v)) }
        var out: [Int] = []
        var moves: [(from: Int, to: Int, merges: Bool)] = []
        var gained = 0
        var i = 0
        while i < tiles.count {
            let to = out.count
            if i + 1 < tiles.count, tiles[i].value == tiles[i + 1].value {
                let merged = tiles[i].value * 2
                out.append(merged)
                gained += merged
                moves.append((tiles[i].index, to, true))
                moves.append((tiles[i + 1].index, to, true))
                i += 2
            } else {
                out.append(tiles[i].value)
                moves.append((tiles[i].index, to, false))
                i += 1
            }
        }
        while out.count < row.count { out.append(0) }
        return (out, gained, moves)
    }

    /// Returns whether the grid changed.
    @discardableResult
    public mutating func move(_ d: Direction) -> Bool {
        guard !isOver else { return false }
        let n = Self.size
        var next = grid
        var gained = 0
        var slides: [Slide] = []
        var merged: Set<Point> = []
        for line in 0..<n {
            let cells = Self.lineCells(line, d)
            let values = cells.map { grid[$0.y][$0.x] }
            let slid = Self.track(row: values)
            gained += slid.gained
            for (k, c) in cells.enumerated() { next[c.y][c.x] = slid.row[k] }
            for m in slid.moves {
                let from = cells[m.from]
                let to = cells[m.to]
                slides.append(Slide(from: from, to: to, value: values[m.from], merges: m.merges))
                if m.merges { merged.insert(to) }
            }
        }
        guard next != grid else { return false }
        grid = next
        score += gained
        let born = spawn()
        let order = merged.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        let serial = (lastMove?.serial ?? 0) + 1
        lastMove = Move(serial: serial, direction: d, slides: slides, merged: order,
                        spawned: born, spawnedValue: born.map { grid[$0.y][$0.x] } ?? 0)
        refresh()
        return true
    }

    /// The cells of line `line`, starting at the edge the tiles slide towards.
    private static func lineCells(_ line: Int, _ d: Direction) -> [Point] {
        let n = size
        switch d {
        case .left: return (0..<n).map { Point(x: $0, y: line) }
        case .right: return (0..<n).map { Point(x: n - 1 - $0, y: line) }
        case .up: return (0..<n).map { Point(x: line, y: $0) }
        case .down: return (0..<n).map { Point(x: line, y: n - 1 - $0) }
        }
    }

    /// Adds a 2 or a 4 in a random empty cell; returns where (nil when the grid is full).
    @discardableResult
    private mutating func spawn() -> Point? {
        var empty: [Point] = []
        for y in 0..<grid.count {
            for x in 0..<grid[y].count where grid[y][x] == 0 { empty.append(Point(x: x, y: y)) }
        }
        guard !empty.isEmpty else { return nil }
        let cell = empty[rng.below(empty.count)]
        grid[cell.y][cell.x] = rng.below(10) == 0 ? 4 : 2
        return cell
    }

    private mutating func refresh() {
        if grid.contains(where: { $0.contains { $0 >= Self.goal } }) { won = true }
        isOver = !canMove
    }

    private var canMove: Bool {
        for y in 0..<grid.count {
            for x in 0..<grid[y].count {
                let v = grid[y][x]
                if v == 0 { return true }
                if x + 1 < grid[y].count, grid[y][x + 1] == v { return true }
                if y + 1 < grid.count, grid[y + 1][x] == v { return true }
            }
        }
        return false
    }
}
