import Foundation

/// 2048 on a 4×4 grid. Advanced by `move` (turn-based: no frame loop). A move that changed
/// the grid spawns a 2 (90%) or a 4 (10%) in a random empty cell; one that did not, spawns
/// nothing. Over when no move can change the grid.
public struct Game2048: Equatable, Sendable {
    public static let size = 4
    public static let goal = 2048

    /// Rows, top first; 0 is empty.
    public private(set) var grid: [[Int]]
    public private(set) var score = 0
    public private(set) var isOver = false
    /// A 2048 tile was made (play may go on).
    public private(set) var won = false
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
        let tiles = row.filter { $0 != 0 }
        var out: [Int] = []
        var gained = 0
        var i = 0
        while i < tiles.count {
            if i + 1 < tiles.count, tiles[i] == tiles[i + 1] {
                let merged = tiles[i] * 2
                out.append(merged)
                gained += merged
                i += 2
            } else {
                out.append(tiles[i])
                i += 1
            }
        }
        while out.count < row.count { out.append(0) }
        return (out, gained)
    }

    /// Returns whether the grid changed.
    @discardableResult
    public mutating func move(_ d: Direction) -> Bool {
        guard !isOver else { return false }
        let n = Self.size
        var next = grid
        var gained = 0
        for line in 0..<n {
            let cells = Self.lineCells(line, d)
            let values = cells.map { grid[$0.y][$0.x] }
            let slid = Self.slide(row: values)
            gained += slid.gained
            for (k, c) in cells.enumerated() { next[c.y][c.x] = slid.row[k] }
        }
        guard next != grid else { return false }
        grid = next
        score += gained
        spawn()
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

    private mutating func spawn() {
        var empty: [Point] = []
        for y in 0..<grid.count {
            for x in 0..<grid[y].count where grid[y][x] == 0 { empty.append(Point(x: x, y: y)) }
        }
        guard !empty.isEmpty else { return }
        let cell = empty[rng.below(empty.count)]
        grid[cell.y][cell.x] = rng.below(10) == 0 ? 4 : 2
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
