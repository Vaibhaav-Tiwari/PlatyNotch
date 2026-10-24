import Foundation
import PlatyNotchKit
import XCTest

/// Feedback round 1: Flappy's original-like physics, 2048's move reports, Tetris's ghost
/// piece and Snake's speed curve and crash point.
final class FlappyFeelTests: XCTestCase {
    func testFallSpeedIsCapped() {
        var f = Flappy(seed: 1)
        f.pipes = []
        f.birdY = 20
        f.step(dt: 0.5)
        XCTAssertEqual(f.velocity, Flappy.maxFallSpeed, accuracy: 0.0001, "terminal velocity, like the original")
        XCTAssertFalse(f.isOver)
    }

    func testTopOfTheSkyStopsButDoesNotEnd() {
        var f = Flappy(seed: 1)
        f.pipes = []
        for _ in 0..<120 {
            f.flap()
            f.step(dt: 1.0 / 60.0)
        }
        XCTAssertFalse(f.isOver)
        XCTAssertEqual(f.birdY, Flappy.birdRadius, accuracy: 0.0001)
    }

    /// One flap from rest rises about 42 units (a tenth of the sky) in about 0.3 s: the
    /// original's hop, far smaller than the gap.
    func testOneFlapHopsATenthOfTheSky() {
        var f = Flappy(seed: 1)
        f.pipes = []
        f.flap()
        let y0 = f.birdY
        var top = y0
        for _ in 0..<60 {
            f.step(dt: 1.0 / 120.0)
            top = min(top, f.birdY)
        }
        let hop = y0 - top
        XCTAssertEqual(hop, 42, accuracy: 2)
        XCTAssertLessThan(hop * 2, Flappy.gapHeight, "two hops fit in a gap")
    }

    /// A simple pilot (flap when below the gap's middle and not already rising) gets
    /// through 25 pipes on every seed: the gaps are always reachable at these constants.
    func testSimplePilotSurvives() {
        for seed: UInt64 in 1...8 {
            var f = Flappy(seed: seed)
            var steps = 0
            while f.score < 25, !f.isOver, steps < 120 * 120 {
                let next = f.pipes.first { $0.x + Flappy.pipeWidth >= Flappy.birdX - Flappy.birdRadius }
                let target: Double = (next?.gapY ?? Flappy.height / 2) + 18
                if f.birdY > target, f.velocity > 0 { f.flap() }
                f.step(dt: 1.0 / 120.0)
                steps += 1
            }
            XCTAssertFalse(f.isOver, "seed \(seed) crashed at \(f.score)")
            XCTAssertGreaterThanOrEqual(f.score, 25)
        }
    }

    func testGapsStayInTheMiddleSixtyPercent() {
        var f = Flappy(seed: 3)
        var gaps: [Double] = []
        for _ in 0..<2000 {
            f.birdY = 200
            f.velocity = 0
            gaps += f.pipes.map(\.gapY)
            f.pipes = f.pipes.filter { $0.x > Flappy.birdX + 40 }   // never hit one
            f.step(dt: 1.0 / 60.0)
        }
        for g in gaps {
            XCTAssertGreaterThanOrEqual(g - Flappy.gapHeight / 2, Flappy.height * 0.2 - 0.0001)
            XCTAssertLessThanOrEqual(g + Flappy.gapHeight / 2, Flappy.height * 0.8 + 0.0001)
        }
    }

    func testWingBeatsAndTiltFollowsSpeed() {
        let p = Flappy.wingPeriod
        XCTAssertEqual(Flappy.wing(at: 0), .up)
        XCTAssertEqual(Flappy.wing(at: p * 0.3), .middle)
        XCTAssertEqual(Flappy.wing(at: p * 0.6), .down)
        XCTAssertEqual(Flappy.wing(at: p * 0.8), .middle)
        XCTAssertEqual(Flappy.wing(at: p * 5.1), .up, "repeats")
        XCTAssertLessThan(Flappy.tilt(velocity: Flappy.flapVelocity), 0, "nose up while rising")
        XCTAssertEqual(Flappy.tilt(velocity: Flappy.maxFallSpeed), 70, accuracy: 0.0001, "dives when falling fast")
        var last = Flappy.tilt(velocity: -300)
        for v in stride(from: -300.0, through: 300, by: 10) {
            let t = Flappy.tilt(velocity: v)
            XCTAssertGreaterThanOrEqual(t, last)
            last = t
        }
    }

    func testTimeAndDistanceAdvanceDeterministically() {
        func run() -> Flappy {
            var f = Flappy(seed: 5)
            for i in 0..<90 {
                if i % 20 == 0 { f.flap() }
                f.step(dt: 1.0 / 60.0)
            }
            return f
        }
        let a = run()
        XCTAssertEqual(a, run())
        XCTAssertEqual(a.time, 1.5, accuracy: 0.0001)
        XCTAssertEqual(a.distance, Flappy.pipeSpeed * 1.5, accuracy: 0.001)
    }
}

final class Game2048MoveTests: XCTestCase {
    func testTrackRow() {
        let r = Game2048.track(row: [2, 0, 2, 4])
        XCTAssertEqual(r.row, [4, 4, 0, 0])
        XCTAssertEqual(r.moves.map(\.from), [0, 2, 3])
        XCTAssertEqual(r.moves.map(\.to), [0, 0, 1])
        XCTAssertEqual(r.moves.map(\.merges), [true, true, false])
        let still = Game2048.track(row: [2, 4, 0, 0])
        XCTAssertEqual(still.moves.map(\.from), still.moves.map(\.to))
    }

    func testMoveReportsSlidesMergesAndSpawn() throws {
        let start = [[2, 2, 0, 4], [0, 0, 0, 0], [0, 8, 0, 0], [0, 0, 0, 0]]
        var g = Game2048(grid: start, seed: 1)
        XCTAssertNil(g.lastMove)
        XCTAssertTrue(g.move(.right))
        let m = try XCTUnwrap(g.lastMove)
        XCTAssertEqual(m.serial, 1)
        XCTAssertEqual(m.direction, .right)
        XCTAssertEqual(m.before, start)
        let merged = m.slides.filter(\.merges)
        XCTAssertEqual(Set(merged.map(\.from)), [Point(x: 0, y: 0), Point(x: 1, y: 0)])
        XCTAssertEqual(Set(merged.map(\.to)), [Point(x: 2, y: 0)])
        XCTAssertEqual(m.merged, [Point(x: 2, y: 0)])
        XCTAssertTrue(m.slides.contains(Game2048.Slide(from: Point(x: 3, y: 0), to: Point(x: 3, y: 0), value: 4, merges: false)))
        XCTAssertTrue(m.slides.contains(Game2048.Slide(from: Point(x: 1, y: 2), to: Point(x: 3, y: 2), value: 8, merges: false)))
        let spawn = try XCTUnwrap(m.spawned)
        XCTAssertEqual(g.grid[spawn.y][spawn.x], m.spawnedValue)
        XCTAssertTrue([2, 4].contains(m.spawnedValue))
    }

    func testNoChangeKeepsTheLastReport() {
        var g = Game2048(grid: [[2, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]], seed: 1)
        XCTAssertTrue(g.move(.right))
        let m = g.lastMove
        let grid = g.grid
        // Find a direction that does nothing (one always exists right after a move? not
        // always), so check: a no-op move never changes the report or the serial.
        for d in Direction.allCases {
            var h = g
            if !h.move(d) {
                XCTAssertEqual(h.lastMove, m)
                XCTAssertEqual(h.grid, grid)
            } else {
                XCTAssertEqual(h.lastMove?.serial, 2)
            }
        }
    }

    /// For many random moves: the report's `before` is the grid before the move, its
    /// slides rebuild the grid after it (less the spawn), merges double, the spawn lands
    /// on a cell the slides left empty, and the same seed gives the same reports.
    func testReportsAgreeWithTheGrid() {
        func run(_ seed: UInt64) -> [Game2048.Move] {
            var g = Game2048(seed: seed)
            var rng = SeededRNG(seed: seed &+ 99)
            var reports: [Game2048.Move] = []
            for _ in 0..<400 where !g.isOver {
                let before = g.grid
                let d = Direction.allCases[rng.below(4)]
                guard g.move(d), let m = g.lastMove else { continue }
                XCTAssertEqual(m.before, before)
                var after = Array(repeating: Array(repeating: 0, count: 4), count: 4)
                for s in m.slides { after[s.to.y][s.to.x] += s.value }
                for p in m.merged { XCTAssertEqual(after[p.y][p.x], g.grid[p.y][p.x]) }
                if let sp = m.spawned {
                    XCTAssertEqual(after[sp.y][sp.x], 0, "spawned on a free cell")
                    after[sp.y][sp.x] = m.spawnedValue
                }
                XCTAssertEqual(after, g.grid)
                XCTAssertEqual(m.serial, reports.count + 1, "one report per changing move")
                reports.append(m)
            }
            return reports
        }
        for seed: UInt64 in [3, 11, 42] {
            let a = run(seed)
            XCTAssertFalse(a.isEmpty)
            XCTAssertEqual(a, run(seed))
        }
    }
}

final class TetrisGhostTests: XCTestCase {
    private static func emptyBoard() -> [[Int]] {
        Array(repeating: Array(repeating: 0, count: 10), count: 20)
    }

    func testGhostLandsOnTheFloor() {
        let t = Tetris(board: Self.emptyBoard(), piece: TetrisPiece(kind: .o, x: 3, y: 0), queue: [.t])
        XCTAssertEqual(t.ghost.x, 3)
        XCTAssertEqual(t.ghost.cells.map(\.y).max(), 19)
    }

    func testGhostRestsOnTheStack() {
        var board = Self.emptyBoard()
        board[15][5] = 3
        let t = Tetris(board: board, piece: TetrisPiece(kind: .i, rotation: 1, x: 3, y: 0), queue: [.t])
        // Vertical I in column 5 (rotation 1 puts it in box column 2): it stops above row 15.
        XCTAssertEqual(Set(t.ghost.cells.map(\.x)), [5])
        XCTAssertEqual(t.ghost.cells.map(\.y).max(), 14)
    }

    func testGhostIsWhereAHardDropLocks() {
        for seed: UInt64 in 1...5 {
            var t = Tetris(seed: seed)
            for i in 0..<30 where !t.isOver {
                if i % 3 == 0 { t.apply(.rotate) }
                if i % 2 == 0 { t.apply(.left) } else { t.apply(.right) }
                let ghost = t.ghost
                let value = t.current.kind.cellValue
                let before = t.board
                t.apply(.hardDrop)
                // The locked cells are exactly the ghost's (unless a line cleared).
                if t.linesCleared == 0 {
                    for c in ghost.cells {
                        XCTAssertEqual(before[c.y][c.x], 0)
                        XCTAssertEqual(t.board[c.y][c.x], value)
                    }
                }
            }
        }
    }

    func testLevel() {
        var t = Tetris(seed: 1)
        XCTAssertEqual(t.level, 1)
        t.linesCleared = 25
        XCTAssertEqual(t.level, 3)
    }
}

final class SnakeSpeedTests: XCTestCase {
    func testStartsSlowerThanBefore() {
        XCTAssertEqual(Snake.stepInterval(score: 0), 0.16, accuracy: 0.0001)
        XCTAssertGreaterThan(Snake.stepInterval(score: 0), 0.11, "slower than the old fixed 0.11 s")
        XCTAssertEqual(GameSession.snakeStep, Snake.stepInterval(score: 0))
    }

    func testSpeedsUpGraduallyAndCaps() {
        var last = Snake.stepInterval(score: 0)
        for n in 1...200 {
            let s = Snake.stepInterval(score: n)
            XCTAssertLessThanOrEqual(s, last)
            XCTAssertGreaterThan(last - s, -0.0001)
            XCTAssertLessThan(last - s, 0.005, "never a jump: no levels")
            XCTAssertGreaterThanOrEqual(s, Snake.fastestStep)
            last = s
        }
        XCTAssertEqual(Snake.stepInterval(score: 10), 0.1241, accuracy: 0.001)
        XCTAssertEqual(Snake.stepInterval(score: 20), 0.0963, accuracy: 0.001)
        XCTAssertEqual(Snake.stepInterval(score: 33), Snake.fastestStep)
        XCTAssertGreaterThan(Snake.stepInterval(score: 32), Snake.fastestStep)
        XCTAssertEqual(Snake.stepInterval(score: -3), Snake.slowestStep)
    }

    func testSessionStepsFasterAfterEating() {
        var s = GameSession(kind: .snake, seed: 1)
        s.setBlockers(GameBlockers())
        _ = s.key(.space)
        s.snake.score = 20   // as if 20 foods were eaten
        s.snake.food = Point(x: 0, y: 0)
        let head = s.snake.body[0]
        s.advance(to: 0)
        s.advance(to: Snake.stepInterval(score: 20) * 2 + 0.001)
        XCTAssertEqual(s.snake.body[0].x, head.x + 2, "two steps at the score-20 interval")
    }

    func testCrashPointOnWallAndSelf() {
        var s = Snake(seed: 1)
        s.food = Point(x: 0, y: 0)
        XCTAssertNil(s.crash)
        while !s.isOver { s.step() }
        XCTAssertEqual(s.crash, s.body[0], "a wall: the head, at the edge")
        XCTAssertEqual(s.crash?.x, s.width - 1)

        var t = Snake(seed: 1)
        t.body = [Point(x: 5, y: 4), Point(x: 4, y: 4), Point(x: 4, y: 5), Point(x: 5, y: 5), Point(x: 6, y: 5)]
        t.food = Point(x: 0, y: 0)
        t.turn(.down)
        t.step()
        XCTAssertTrue(t.isOver)
        XCTAssertEqual(t.crash, Point(x: 5, y: 5), "itself: the body cell it ran into")
    }
}

/// The views' one-shot animations (Snake's death, a 2048 move) play when these session
/// counters go up; a new game must not change them.
final class GameAnimationTriggerTests: XCTestCase {
    func testSnakeDeathsCountDeathsOnly() {
        var s = GameSession(kind: .snake, seed: 1)
        s.setBlockers(GameBlockers())
        _ = s.key(.space)
        XCTAssertEqual(s.snakeDeaths, 0)
        s.snake.food = Point(x: 0, y: 0)
        var t = 0.0
        s.advance(to: t)
        while s.phase == .playing, t < 30 {
            t += 0.05
            s.advance(to: t)
        }
        XCTAssertEqual(s.phase, .over)
        XCTAssertEqual(s.snakeDeaths, 1)
        _ = s.key(.space)   // a new game
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.snakeDeaths, 1, "a new game plays no death animation")
    }

    func testMoves2048CountMovesOnly() {
        var s = GameSession(kind: .twenty48, seed: 3)
        s.setBlockers(GameBlockers())
        _ = s.key(.space)
        XCTAssertEqual(s.moves2048, 0)
        var moved = 0
        for k in [GameKey.left, .right, .up, .down, .left, .right] {
            let before = s.game2048.lastMove?.serial
            _ = s.key(k)
            if s.game2048.lastMove?.serial != before { moved += 1 }
        }
        XCTAssertGreaterThan(moved, 0)
        XCTAssertEqual(s.moves2048, moved, "one per move that changed the grid")
        _ = s.key(.escape)
        _ = s.key(.space)   // resume
        XCTAssertEqual(s.moves2048, moved, "pausing and resuming plays nothing")
    }
}
