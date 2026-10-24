import Foundation
import PlatyNotchKit   // not @testable: the UI uses these types through their public API (C6)
import XCTest

final class SeededRNGTests: XCTestCase {
    /// SplitMix64's published first output for seed 0.
    func testSplitMix64KnownVector() {
        var rng = SeededRNG(seed: 0)
        XCTAssertEqual(rng.next(), 0xE220_A839_7B1D_CDAF)
        XCTAssertEqual(rng.next(), 0x6E78_9E6A_A1B9_65F4)
    }

    func testSameSeedSameSequence() {
        var a = SeededRNG(seed: 42)
        var b = SeededRNG(seed: 42)
        var c = SeededRNG(seed: 43)
        let sa = (0..<16).map { _ in a.next() }
        let sb = (0..<16).map { _ in b.next() }
        let sc = (0..<16).map { _ in c.next() }
        XCTAssertEqual(sa, sb)
        XCTAssertNotEqual(sa, sc)
    }

    func testBelowStaysInRange() {
        var rng = SeededRNG(seed: 7)
        for n in 1...20 {
            for _ in 0..<50 { XCTAssertTrue((0..<n).contains(rng.below(n))) }
        }
    }
}

final class SnakeTests: XCTestCase {
    func testStartsInsideBoardWithFoodOffBody() {
        let s = Snake(seed: 1)
        XCTAssertEqual(s.width, 24)
        XCTAssertEqual(s.height, 8)
        XCTAssertEqual(s.body.count, 3)
        XCTAssertFalse(s.body.contains(s.food))
        XCTAssertFalse(s.isOver)
    }

    func testGrowsOnFood() {
        var s = Snake(seed: 1)
        let head = s.body[0]
        s.food = Point(x: head.x + 1, y: head.y)   // heading right
        s.step()
        XCTAssertEqual(s.body.count, 4)
        XCTAssertEqual(s.body[0], Point(x: head.x + 1, y: head.y))
        XCTAssertEqual(s.score, 1)
        XCTAssertFalse(s.body.contains(s.food), "new food never lands on the snake")
        XCTAssertFalse(s.isOver)
    }

    func testMovesWithoutGrowingAwayFromFood() {
        var s = Snake(seed: 1)
        s.food = Point(x: 0, y: 0)
        let head = s.body[0]
        s.step()
        XCTAssertEqual(s.body.count, 3)
        XCTAssertEqual(s.body[0], Point(x: head.x + 1, y: head.y))
        XCTAssertEqual(s.score, 0)
    }

    func testDiesOnWall() {
        var s = Snake(seed: 1)
        s.food = Point(x: 0, y: 0)
        var steps = 0
        while !s.isOver && steps < 100 {
            s.step()
            steps += 1
            XCTAssertTrue(s.body.allSatisfy { (0..<s.width).contains($0.x) && (0..<s.height).contains($0.y) })
        }
        XCTAssertTrue(s.isOver)
        XCTAssertEqual(steps, s.width - Snake.startHeadX, "dies on the step that would leave the board")
        let before = s.body
        s.step()
        XCTAssertEqual(s.body, before, "a finished game does not move")
    }

    func testCannotReverse() {
        var s = Snake(seed: 1)
        s.food = Point(x: 0, y: 0)
        let head = s.body[0]
        s.turn(.left)   // straight back into itself: ignored
        s.step()
        XCTAssertEqual(s.body[0], Point(x: head.x + 1, y: head.y))
        XCTAssertFalse(s.isOver)
        // Two quick turns within one step cannot reverse either (up, then left before the step).
        s.turn(.up)
        s.turn(.left)
        s.step()
        XCTAssertEqual(s.body[0], Point(x: head.x + 1, y: head.y - 1))
    }

    func testDiesOnSelf() {
        var s = Snake(seed: 1)
        s.body = [Point(x: 5, y: 4), Point(x: 4, y: 4), Point(x: 4, y: 5), Point(x: 5, y: 5), Point(x: 6, y: 5)]
        s.food = Point(x: 0, y: 0)
        s.turn(.down)   // heading right; down runs into (5,5)
        s.step()
        XCTAssertTrue(s.isOver)
    }

    func testDeterministic() {
        func run(_ seed: UInt64) -> [Point] {
            var s = Snake(seed: seed)
            var foods: [Point] = []
            for i in 0..<12 {
                s.food = Point(x: s.body[0].x + 1, y: s.body[0].y)   // eat every step: a new random food each time
                s.step()
                foods.append(s.food)
                if i == 5 { s.turn(.down) }
                if s.isOver { break }
            }
            return foods
        }
        XCTAssertEqual(run(9), run(9))
        XCTAssertEqual(Snake(seed: 9).food, Snake(seed: 9).food)
    }
}

final class TetrisTests: XCTestCase {
    private static func emptyBoard() -> [[Int]] {
        Array(repeating: Array(repeating: 0, count: 10), count: 20)
    }

    func testLineClearScores100() {
        var board = Self.emptyBoard()
        for x in 4..<10 { board[19][x] = 2 }   // bottom row, gap at columns 0-3
        var t = Tetris(board: board, piece: TetrisPiece(kind: .i, rotation: 0, x: 0, y: 0), queue: [.o, .t])
        t.apply(.hardDrop)
        XCTAssertEqual(t.linesCleared, 1)
        XCTAssertEqual(t.score, 100)
        XCTAssertEqual(t.board[19], Array(repeating: 0, count: 10), "the cleared row is gone")
        XCTAssertEqual(t.current.kind, .o, "the next piece comes from the queue")
    }

    func testTwoAndThreeLinesScore300And500() {
        for (rows, expected) in [(2, 300), (3, 500)] {
            var board = Self.emptyBoard()
            for y in (20 - rows)..<20 { for x in 0..<9 { board[y][x] = 1 } }
            var t = Tetris(board: board, piece: TetrisPiece(kind: .i, rotation: 1, x: 7, y: 0), queue: [.o])
            t.apply(.hardDrop)
            XCTAssertEqual(t.linesCleared, rows)
            XCTAssertEqual(t.score, expected)
        }
    }

    func testTetrisScores800() {
        var board = Self.emptyBoard()
        for y in 16..<20 { for x in 0..<9 { board[y][x] = 3 } }   // column 9 open
        // Vertical I: rotation 1 sits in box column 2, so x 7 is board column 9.
        var t = Tetris(board: board, piece: TetrisPiece(kind: .i, rotation: 1, x: 7, y: 0), queue: [.o])
        XCTAssertEqual(Set(t.current.cells.map(\.x)), [9])
        t.apply(.hardDrop)
        XCTAssertEqual(t.linesCleared, 4)
        XCTAssertEqual(t.score, 800)
        XCTAssertTrue(t.board.allSatisfy { $0.allSatisfy { $0 == 0 } })
    }

    func testRotateKicksOffWall() {
        // Vertical I against the right wall: rotating straight in place would put a cell
        // at column 10, so the kick (0, -1, …) moves it one left.
        var t = Tetris(board: Self.emptyBoard(), piece: TetrisPiece(kind: .i, rotation: 1, x: 7, y: 5), queue: [.o])
        t.apply(.rotate)
        XCTAssertEqual(t.current.rotation, 2)
        XCTAssertEqual(t.current.x, 6)
        XCTAssertTrue(t.current.cells.allSatisfy { (0..<10).contains($0.x) })
        XCTAssertEqual(Set(t.current.cells.map(\.y)).count, 1, "horizontal now")
    }

    func testRotateBlockedEverywhereStays() {
        var board = Self.emptyBoard()
        for x in 0..<10 where x != 9 { board[7][x] = 1 }   // the row a horizontal I would need
        let piece = TetrisPiece(kind: .i, rotation: 1, x: 7, y: 5)
        var t = Tetris(board: board, piece: piece, queue: [.o])
        t.apply(.rotate)
        XCTAssertEqual(t.current, piece)
    }

    func testSevenBagHasAllPieces() {
        let t = Tetris(seed: 5)
        let first = [t.current.kind] + Array(t.queue.prefix(6))
        XCTAssertEqual(Set(first), Set(Tetromino.allCases))
        XCTAssertGreaterThanOrEqual(t.queue.count, 13)
        XCTAssertEqual(Set(t.queue[6..<13]), Set(Tetromino.allCases), "the second bag too")
    }

    func testSevenBagAcrossManyPieces() {
        var t = Tetris(width: 10, height: 20, seed: 11)
        var kinds: [Tetromino] = []
        for _ in 0..<21 {
            kinds.append(t.current.kind)
            t.board = Self.emptyBoard()   // keep it from topping out
            t.apply(.hardDrop)
        }
        for bag in 0..<3 {
            XCTAssertEqual(Set(kinds[(bag * 7)..<(bag * 7 + 7)]), Set(Tetromino.allCases))
        }
    }

    func testMovesStayInsideAndTickLocks() {
        var t = Tetris(board: Self.emptyBoard(), piece: TetrisPiece(kind: .o, rotation: 0, x: 4, y: 0), queue: [.t])
        for _ in 0..<12 { t.apply(.left) }
        XCTAssertEqual(t.current.cells.map(\.x).min(), 0)
        for _ in 0..<12 { t.apply(.right) }
        XCTAssertEqual(t.current.cells.map(\.x).max(), 9)
        for _ in 0..<18 { t.tick() }   // O falls from rows 0-1 to rows 18-19
        XCTAssertEqual(t.current.kind, .o)
        XCTAssertEqual(t.current.y, 18)
        t.tick()   // cannot fall further: locks, the next spawns
        XCTAssertEqual(t.current.kind, .t)
        XCTAssertEqual(t.board[19][9], Tetromino.o.cellValue)
        XCTAssertEqual(t.board[18][8], Tetromino.o.cellValue)
    }

    func testSoftDropMovesOneRow() {
        var t = Tetris(board: Self.emptyBoard(), piece: TetrisPiece(kind: .t, rotation: 0, x: 3, y: 0), queue: [.o])
        t.apply(.softDrop)
        XCTAssertEqual(t.current.y, 1)
        XCTAssertEqual(t.score, 0)
    }

    func testTopOutEndsGame() {
        var board = Self.emptyBoard()
        for x in 3..<7 { board[1][x] = 1 }   // where the next piece spawns
        var t = Tetris(board: board, piece: TetrisPiece(kind: .i, rotation: 1, x: -2, y: 4), queue: [.o])
        t.apply(.hardDrop)   // column 0, no line: the O cannot spawn
        XCTAssertTrue(t.isOver)
        let after = t
        t.apply(.hardDrop)
        t.apply(.left)
        t.tick()
        XCTAssertEqual(t, after, "a finished game takes no input")
    }

    func testDeterministic() {
        func run(_ seed: UInt64) -> [Tetromino] {
            var t = Tetris(seed: seed)
            var out: [Tetromino] = []
            for _ in 0..<15 {
                out.append(t.current.kind)
                t.board = Self.emptyBoard()
                t.apply(.hardDrop)
            }
            return out
        }
        XCTAssertEqual(run(3), run(3))
        XCTAssertNotEqual(run(3), run(4))
    }

    func testTickIntervalSpeedsUp() {
        var t = Tetris(seed: 1)
        let slow = t.tickInterval
        t.linesCleared = 30
        XCTAssertLessThan(t.tickInterval, slow)
        t.linesCleared = 10_000
        XCTAssertGreaterThanOrEqual(t.tickInterval, Tetris.fastestTick)
    }
}

final class Game2048Tests: XCTestCase {
    func testMergeRowLeft() {
        let r = Game2048.slide(row: [2, 2, 2, 2])
        XCTAssertEqual(r.row, [4, 4, 0, 0])
        XCTAssertEqual(r.gained, 8)
    }

    func testNoDoubleMerge() {
        XCTAssertEqual(Game2048.slide(row: [4, 4, 8, 0]).row, [8, 8, 0, 0])
        XCTAssertEqual(Game2048.slide(row: [0, 2, 0, 2]).row, [4, 0, 0, 0])
        XCTAssertEqual(Game2048.slide(row: [2, 2, 4, 0]).row, [4, 4, 0, 0])
        XCTAssertEqual(Game2048.slide(row: [2, 4, 8, 16]).row, [2, 4, 8, 16])
    }

    func testStartsWithTwoTiles() {
        let g = Game2048(seed: 3)
        XCTAssertEqual(g.grid.flatMap { $0 }.filter { $0 != 0 }.count, 2)
        XCTAssertTrue(g.grid.flatMap { $0 }.allSatisfy { [0, 2, 4].contains($0) })
    }

    func testMoveRightSpawnsOneTileAndScores() {
        var g = Game2048(grid: [[2, 2, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], seed: 1)
        XCTAssertTrue(g.move(.right))
        XCTAssertEqual(g.grid[0][3], 4)
        XCTAssertEqual(g.score, 4)
        XCTAssertEqual(g.grid.flatMap { $0 }.filter { $0 != 0 }.count, 2, "one new tile")
    }

    func testMoveUpAndDownUseColumns() {
        var g = Game2048(grid: [[2, 0, 0, 0], [2, 0, 0, 0], [4, 0, 0, 0], [0, 0, 0, 0]], seed: 1)
        XCTAssertTrue(g.move(.up))
        XCTAssertEqual(g.grid[0][0], 4)
        XCTAssertEqual(g.grid[1][0], 4)
        var h = Game2048(grid: [[2, 0, 0, 0], [2, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], seed: 1)
        XCTAssertTrue(h.move(.down))
        XCTAssertEqual(h.grid[3][0], 4)
    }

    func testNoSpawnWhenNoChange() {
        let grid = [[2, 0, 0, 0], [4, 0, 0, 0], [8, 0, 0, 0], [16, 0, 0, 0]]
        var g = Game2048(grid: grid, seed: 1)
        XCTAssertFalse(g.move(.left))
        XCTAssertEqual(g.grid, grid, "nothing moved: no tile spawned")
        XCTAssertEqual(g.score, 0)
        XCTAssertFalse(g.move(.up))
        XCTAssertEqual(g.grid, grid)
        XCTAssertTrue(g.move(.right), "the same grid can still move the other way")
        XCTAssertNotEqual(g.grid, grid)
    }

    func testGameOverDetection() {
        let stuck = [[2, 4, 2, 4], [4, 2, 4, 2], [2, 4, 2, 4], [4, 2, 4, 2]]
        var g = Game2048(grid: stuck, seed: 1)
        XCTAssertTrue(g.isOver)
        for d in Direction.allCases { XCTAssertFalse(g.move(d)) }
        let mergeable = [[2, 4, 2, 4], [4, 2, 4, 2], [2, 4, 2, 4], [4, 2, 4, 4]]
        XCTAssertFalse(Game2048(grid: mergeable, seed: 1).isOver, "full but a merge is left")
        // The last move fills the grid with no merge left: over.
        // The spawn (2 or 4) lands at column 0 under an 8, beside a 16: no merge either way.
        for seed: UInt64 in 1...6 {
            var h = Game2048(grid: [[2, 4, 2, 4], [4, 2, 4, 2], [8, 4, 2, 4], [16, 32, 16, 0]], seed: seed)
            XCTAssertFalse(h.isOver)
            XCTAssertTrue(h.move(.right))
            XCTAssertTrue(h.isOver, "\(h.grid)")
        }
    }

    func testWonAt2048() {
        var g = Game2048(grid: [[1024, 1024, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], seed: 1)
        XCTAssertFalse(g.won)
        XCTAssertTrue(g.move(.left))
        XCTAssertTrue(g.won)
    }

    func testDeterministic() {
        func run(_ seed: UInt64) -> [[Int]] {
            var g = Game2048(seed: seed)
            for d in [Direction.left, .up, .right, .down, .left, .up] { _ = g.move(d) }
            return g.grid
        }
        XCTAssertEqual(run(8), run(8))
    }
}

final class FlappyTests: XCTestCase {
    func testGravityAndFlap() {
        var f = Flappy(seed: 1)
        let y0 = f.birdY
        f.step(dt: 0.1)
        XCTAssertGreaterThan(f.birdY, y0, "falls (y grows downwards)")
        f.flap()
        let y1 = f.birdY
        f.step(dt: 0.05)
        XCTAssertLessThan(f.birdY, y1, "a flap lifts it")
        XCTAssertFalse(f.isOver)
    }

    func testPipeCollisionEndsGame() {
        var f = Flappy(seed: 1)
        f.birdY = 100
        f.pipes = [Flappy.Pipe(x: Flappy.birdX - 5, gapY: 30, gapHeight: 40)]   // gap 10…50; the bird is below it
        f.step(dt: 0.001)
        XCTAssertTrue(f.isOver)
    }

    func testThroughTheGapScores() {
        var f = Flappy(seed: 1)
        f.birdY = 70
        f.velocity = 0
        f.pipes = [Flappy.Pipe(x: Flappy.birdX - Flappy.pipeWidth + 1, gapY: 70, gapHeight: 60)]
        for _ in 0..<5 {
            f.flap()   // hold height
            f.step(dt: 0.02)
        }
        XCTAssertFalse(f.isOver)
        XCTAssertEqual(f.score, 1)
    }

    func testFloorEndsGame() {
        var f = Flappy(seed: 1)
        var t = 0
        while !f.isOver && t < 1000 {
            f.step(dt: 1.0 / 60.0)
            t += 1
        }
        XCTAssertTrue(f.isOver)
        let y = f.birdY
        f.step(dt: 0.1)
        XCTAssertEqual(f.birdY, y, "a finished game does not move")
    }

    func testPipesSpawnAndScrollDeterministically() {
        func run(_ seed: UInt64) -> [Double] {
            var f = Flappy(seed: seed)
            for _ in 0..<240 {
                f.birdY = f.pipes.first?.gapY ?? Flappy.height / 2   // keep it alive
                f.velocity = 0
                f.step(dt: 1.0 / 60.0)
            }
            return f.pipes.map(\.gapY)
        }
        XCTAssertFalse(run(4).isEmpty)
        XCTAssertEqual(run(4), run(4))
    }
}

final class HighScoresTests: XCTestCase {
    func testHighScoreRecord() {
        var h = HighScores()
        XCTAssertEqual(h.best("snake"), 0)
        XCTAssertTrue(h.record(game: "snake", score: 5))
        XCTAssertEqual(h.best("snake"), 5)
        XCTAssertFalse(h.record(game: "snake", score: 5), "a tie is not a new best")
        XCTAssertFalse(h.record(game: "snake", score: 3))
        XCTAssertTrue(h.record(game: "snake", score: 9))
        XCTAssertEqual(h.best("snake"), 9)
        XCTAssertEqual(h.best("tetris"), 0, "per game")
        XCTAssertFalse(h.record(game: "tetris", score: 0), "zero is never a best")
    }

    func testRoundTripsThroughDefaults() throws {
        let name = "HighScoresTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(HighScores.load(from: defaults), HighScores())
        var h = HighScores()
        _ = h.record(game: "2048", score: 1200)
        h.save(to: defaults)
        XCTAssertEqual(HighScores.load(from: defaults).best("2048"), 1200)
        defaults.set(Data("junk".utf8), forKey: HighScores.key)
        XCTAssertEqual(HighScores.load(from: defaults), HighScores(), "a damaged value starts fresh")
    }
}

final class GameKeyTests: XCTestCase {
    func testArrowsSpaceWASDOnly() {
        XCTAssertEqual(GameKey(keyCode: 123, characters: nil, modifiers: []), .left)
        XCTAssertEqual(GameKey(keyCode: 124, characters: nil, modifiers: []), .right)
        XCTAssertEqual(GameKey(keyCode: 125, characters: nil, modifiers: []), .down)
        XCTAssertEqual(GameKey(keyCode: 126, characters: nil, modifiers: []), .up)
        XCTAssertEqual(GameKey(keyCode: 49, characters: " ", modifiers: []), .space)
        XCTAssertEqual(GameKey(keyCode: 53, characters: nil, modifiers: []), .escape)
        XCTAssertEqual(GameKey(keyCode: 13, characters: "w", modifiers: []), .up)
        XCTAssertEqual(GameKey(keyCode: 0, characters: "a", modifiers: []), .left)
        XCTAssertEqual(GameKey(keyCode: 1, characters: "S", modifiers: [.shift]), .down)
        XCTAssertEqual(GameKey(keyCode: 2, characters: "d", modifiers: []), .right)
        XCTAssertNil(GameKey(keyCode: 36, characters: "\r", modifiers: []), "Return is not a game key")
        XCTAssertNil(GameKey(keyCode: 12, characters: "q", modifiers: []))
    }

    /// ⌘↩ / ⌘⌫ belong to the approval cards; no ⌘ (or ⌃ / ⌥) chord is ever a game key.
    func testModifiedKeysAreNeverGameKeys() {
        for m: Set<GameKey.Modifier> in [[.command], [.control], [.option], [.command, .shift]] {
            XCTAssertNil(GameKey(keyCode: 36, characters: "\r", modifiers: m))
            XCTAssertNil(GameKey(keyCode: 51, characters: "\u{7f}", modifiers: m))
            XCTAssertNil(GameKey(keyCode: 123, characters: nil, modifiers: m))
            XCTAssertNil(GameKey(keyCode: 49, characters: " ", modifiers: m))
            XCTAssertNil(GameKey(keyCode: 13, characters: "w", modifiers: m))
        }
    }
}

final class GameSessionTests: XCTestCase {
    private let clear = GameBlockers()

    private func playing(_ kind: GameKind, seed: UInt64 = 1) -> GameSession {
        var s = GameSession(kind: kind, seed: seed)
        s.setBlockers(clear)
        XCTAssertTrue(s.key(.space))
        XCTAssertEqual(s.phase, .playing)
        return s
    }

    func testSpaceStartsAndFramesAdvance() {
        var s = playing(.snake)
        let head = s.snake.body[0]
        s.advance(to: 10)   // the first frame only sets the clock
        s.advance(to: 10 + GameSession.snakeStep * 2 + 0.001)
        XCTAssertEqual(s.snake.body[0].x, head.x + 2)
        XCTAssertTrue(s.isRunning)
    }

    func testApprovalPausesAndKeysDoNotReachTheGame() {
        var s = playing(.snake)
        s.advance(to: 1)
        s.advance(to: 1 + GameSession.snakeStep + 0.001)
        let snapshot = s.snake
        var blocked = clear
        blocked.approval = true
        s.setBlockers(blocked)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertFalse(s.isRunning)
        for k in [GameKey.up, .down, .left, .right, .space, .escape] {
            XCTAssertFalse(s.key(k), "\(k) goes to the approval cards, not the game")
        }
        s.advance(to: 100)
        XCTAssertEqual(s.snake, snapshot, "no frame, no key changed the game")
        XCTAssertEqual(s.phase, .paused)
    }

    func testResumeRestoresExactState() {
        var s = playing(.tetris, seed: 4)
        s.advance(to: 0)
        s.advance(to: 1.7)
        _ = s.key(.left)
        let snapshot = s.tetris
        var blocked = clear
        blocked.approval = true
        s.setBlockers(blocked)
        s.advance(to: 50)
        s.setBlockers(clear)
        XCTAssertEqual(s.phase, .paused, "answering the approval does not resume by itself")
        XCTAssertEqual(s.tetris, snapshot)
        XCTAssertTrue(s.key(.space))
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.tetris, snapshot, "Space resumes; it does not drop the piece")
        s.advance(to: 60)   // first frame after resume: clock only, no catch-up for time paused
        XCTAssertEqual(s.tetris, snapshot)
    }

    func testRingingPausesAndSpaceWaits() {
        var s = playing(.flappy)
        var ringing = clear
        ringing.ringing = true
        s.setBlockers(ringing)
        XCTAssertEqual(s.phase, .paused)
        let bird = s.flappy
        XCTAssertTrue(s.key(.space), "taken, so it does not reach the panel")
        XCTAssertEqual(s.phase, .paused, "cannot resume while something rings")
        XCTAssertEqual(s.flappy, bird)
    }

    func testEveryBlockerPauses() {
        let reasons: [(inout GameBlockers) -> Void] = [
            { $0.approval = true }, { $0.ringing = true }, { $0.collapsed = true },
            { $0.keyLost = true }, { $0.fullScreen = true },
        ]
        for set in reasons {
            var s = playing(.snake)
            var b = clear
            set(&b)
            XCTAssertTrue(b.isBlocked)
            s.setBlockers(b)
            XCTAssertEqual(s.phase, .paused)
            XCTAssertFalse(s.isRunning)
        }
    }

    func testEscapePausesThenPassesThrough() {
        var s = playing(.snake)
        XCTAssertTrue(s.key(.escape))
        XCTAssertEqual(s.phase, .paused)
        XCTAssertFalse(s.key(.escape), "a second Escape goes to the panel (closes it)")
    }

    /// Space held through a game over (or a pause) auto-repeats: the repeats never skip the
    /// game-over screen, start or resume a game, or slam piece after piece.
    func testHeldSpaceNeverRestartsOrResumes() {
        let held = GameKey(.space, isRepeat: true)
        var s = GameSession(kind: .snake, seed: 1)
        s.setBlockers(clear)
        XCTAssertTrue(s.key(held))
        XCTAssertEqual(s.phase, .ready, "a repeat does not start")
        XCTAssertTrue(s.key(.space))
        s.advance(to: 0)
        while s.phase == .playing { s.snake.step(); s.advance(to: 0) }   // run into the wall
        XCTAssertEqual(s.phase, .over)
        let over = s
        XCTAssertTrue(s.key(held), "taken (not passed to the panel)")
        XCTAssertEqual(s, over, "the game-over screen stays")
        XCTAssertTrue(s.key(.escape) == false)
        XCTAssertTrue(s.key(.space))
        XCTAssertEqual(s.phase, .playing, "a fresh press restarts")
        XCTAssertTrue(s.key(.escape))
        XCTAssertTrue(s.key(held))
        XCTAssertEqual(s.phase, .paused, "a repeat does not resume")

        var t = playing(.tetris)
        let piece = t.tetris
        XCTAssertTrue(t.key(held))
        XCTAssertEqual(t.tetris, piece, "a repeat does not slam another piece")
        XCTAssertTrue(t.key(.space))
        XCTAssertNotEqual(t.tetris, piece)

        var f = playing(.flappy)
        let bird = f.flappy.velocity
        XCTAssertTrue(f.key(held))
        XCTAssertNotEqual(f.flappy.velocity, bird, "holding Space still flaps")
    }

    func testGame2048NeedsNoFrames() {
        var s = playing(.twenty48)
        XCTAssertFalse(s.isRunning, "turn-based: no frame loop")
        let before = s.game2048
        var moved = false
        for k in [GameKey.left, .right, .up, .down] where !moved {
            moved = s.key(k) && s.game2048 != before
        }
        XCTAssertTrue(moved)
    }

    func testGameOverRecordsNewBest() {
        var s = playing(.snake)
        s.snake.food = Point(x: s.snake.body[0].x + 1, y: s.snake.body[0].y)
        s.advance(to: 0)
        s.advance(to: GameSession.snakeStep + 0.0001)   // eats
        XCTAssertEqual(s.snake.score, 1)
        s.snake.food = Point(x: 0, y: 0)   // behind it: nothing more to eat on the way to the wall
        var t = GameSession.snakeStep
        while s.phase == .playing && t < 10 {
            t += GameSession.snakeStep
            s.advance(to: t + 0.0001)
        }
        XCTAssertEqual(s.phase, .over)
        XCTAssertEqual(s.scores.best("snake"), 1)
        XCTAssertEqual(s.newBest, GameResult(kind: .snake, score: 1))
        XCTAssertFalse(s.isRunning)
        // Space after game over starts a fresh game.
        XCTAssertTrue(s.key(.space))
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.snake.score, 0)
        XCTAssertNil(s.newBest)
    }

    func testSwitchingGamesPausesAndKeepsEach() {
        var s = playing(.snake)
        s.advance(to: 0)
        s.advance(to: GameSession.snakeStep + 0.001)
        let snake = s.snake
        s.select(.tetris)
        XCTAssertEqual(s.kind, .tetris)
        XCTAssertEqual(s.phase, .ready)
        s.select(.snake)
        XCTAssertEqual(s.phase, .paused)
        XCTAssertEqual(s.snake, snake)
    }

    func testSameSeedSamePlay() {
        func run() -> Tetris {
            var s = GameSession(kind: .tetris, seed: 77)
            s.setBlockers(GameBlockers())
            _ = s.key(.space)
            s.advance(to: 0)
            for i in 1...40 {
                if i % 7 == 0 { _ = s.key(.space) }   // hard drop
                if i % 3 == 0 { _ = s.key(.left) }
                s.advance(to: Double(i) * 0.25)
            }
            return s.tetris
        }
        XCTAssertEqual(run(), run())
    }

    func testBoardsFitTheExpandedPanel() {
        // Tab content below the tab bar: panel height − notch inset (≤ 40) − bottom padding − tab bar − spacing.
        let room = CGSize(width: PanelLayout.expandedSize.width - 24,
                          height: PanelLayout.expandedSize.height - 40 - 10 - 22 - 8)
        XCTAssertLessThanOrEqual(GameLayout.tabSize.width, room.width)
        XCTAssertLessThanOrEqual(GameLayout.tabSize.height, room.height)
        for kind in GameKind.allCases {
            let b = GameLayout.boardSize(kind)
            XCTAssertLessThanOrEqual(b.width, GameLayout.boardArea.width, "\(kind)")
            XCTAssertLessThanOrEqual(b.height, GameLayout.boardArea.height, "\(kind)")
        }
    }
}
