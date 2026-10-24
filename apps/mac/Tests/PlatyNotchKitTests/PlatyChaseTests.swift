import Foundation
import PlatyNotchKit
import XCTest

/// Platy Chase: the maze, the rule tables against the reference (Pac-Man Dossier,
/// Table A.1), the mode schedule, the four targets, cornering, the tunnel, frightened
/// mode, collisions, scoring, the ghost house and Elroy.
final class ChaseMazeTests: XCTestCase {
    private let walkable: Set<ChaseTile> = [.dot, .pellet, .empty]

    func testSizeDotsAndPellets() {
        XCTAssertEqual(ChaseMaze.layout.count, 31)
        XCTAssertTrue(ChaseMaze.layout.allSatisfy { $0.count == 28 })
        XCTAssertEqual(ChaseMaze.dotCount, 240)
        XCTAssertEqual(ChaseMaze.pelletCount, 4)
    }

    func testPelletsInTheFourCornerRegions() {
        var quadrants: Set<Int> = []
        for (y, row) in ChaseMaze.tiles.enumerated() {
            for (x, t) in row.enumerated() where t == .pellet {
                XCTAssertTrue(x <= 3 || x >= 24, "near a side")
                quadrants.insert((x < 14 ? 0 : 1) + (y < 15 ? 0 : 2))
            }
        }
        XCTAssertEqual(quadrants, [0, 1, 2, 3])
    }

    func testSymmetricConnectedNoDeadEndsNoWideCorridors() {
        let t = ChaseMaze.tiles
        for row in ChaseMaze.layout { XCTAssertEqual(String(row.reversed()), row, "left-right symmetric") }
        var open: [Point] = []
        for y in 0..<31 {
            for x in 0..<28 where walkable.contains(t[y][x]) {
                open.append(Point(x: x, y: y))
                var exits = 0
                for d in Direction.allCases where walkable.contains(ChaseMaze.tile(x + d.dx, y + d.dy))
                    || ChaseMaze.tile(x + d.dx, y + d.dy) == .door { exits += 1 }
                XCTAssertGreaterThanOrEqual(exits, 2, "dead end at \(x),\(y)")
                if x < 27, y < 30 {
                    let square = [t[y][x], t[y][x + 1], t[y + 1][x], t[y + 1][x + 1]]
                    XCTAssertFalse(square.allSatisfy { walkable.contains($0) }, "2x2 open at \(x),\(y)")
                }
            }
        }
        var seen: Set<Point> = [Point(x: 13, y: 23)]
        var stack = [Point(x: 13, y: 23)]
        while let p = stack.popLast() {
            for d in Direction.allCases {
                let q = Point(x: ((p.x + d.dx) % 28 + 28) % 28, y: p.y + d.dy)
                if walkable.contains(ChaseMaze.tile(q.x, q.y)), !seen.contains(q) {
                    seen.insert(q)
                    stack.append(q)
                }
            }
        }
        XCTAssertEqual(seen.count, open.count, "every corridor reachable")
    }

    func testHouseTunnelAndStarts() {
        XCTAssertEqual(ChaseMaze.tile(13, 12), .door)
        XCTAssertEqual(ChaseMaze.tile(14, 12), .door)
        XCTAssertEqual(ChaseMaze.tile(14, 14), .house)
        XCTAssertEqual(ChaseMaze.tile(0, 14), .empty, "the tunnel opens at both ends")
        XCTAssertEqual(ChaseMaze.tile(27, 14), .empty)
        XCTAssertEqual(ChaseMaze.tile(-1, 14), .empty)
        XCTAssertEqual(ChaseMaze.tile(-1, 13), .wall)
        XCTAssertTrue(ChaseMaze.isTunnel(2, 14))
        XCTAssertFalse(ChaseMaze.isTunnel(9, 14))
        // Classic start positions: the player at (13.5, 23) between tiles 13 and 14 with
        // no dots under it, the direct chaser above the door, the rest inside.
        XCTAssertEqual(ChaseMaze.playerStart.x, 14)
        XCTAssertEqual(ChaseMaze.tile(13, 23), .empty)
        XCTAssertEqual(ChaseMaze.tile(14, 23), .empty)
        XCTAssertEqual(ChaseMaze.tile(13, 11), .empty)
        XCTAssertEqual(ChaseMaze.tile(13, 17), .empty, "the bonus spot")
    }
}

final class ChaseRulesTests: XCTestCase {
    func testLevelOneTable() {
        let l = ChaseRules.level(1)
        XCTAssertEqual(l.playerSpeed, 0.80)
        XCTAssertEqual(l.playerFrightSpeed, 0.90)
        XCTAssertEqual(l.chaserSpeed, 0.75)
        XCTAssertEqual(l.chaserFrightSpeed, 0.50)
        XCTAssertEqual(l.chaserTunnelSpeed, 0.40)
        XCTAssertEqual(l.elroy1Dots, 20)
        XCTAssertEqual(l.elroy1Speed, 0.80)
        XCTAssertEqual(l.elroy2Dots, 10)
        XCTAssertEqual(l.elroy2Speed, 0.85)
        XCTAssertEqual(l.frightTime, 6)
        XCTAssertEqual(l.frightFlashes, 5)
        XCTAssertEqual(l.schedule, [7, 20, 7, 20, 5, 20, 5])
        XCTAssertEqual(l.bonus, .shrimp)
        XCTAssertEqual(l.bonus.points, 100)
        XCTAssertEqual(l.houseDotLimits, [0, 30, 60])
        XCTAssertEqual(l.dotTimerLimit, 4)
        XCTAssertEqual(ChaseRules.maxSpeed * 8, 75.75757625, accuracy: 1e-9)
    }

    func testLaterLevels() {
        let two = ChaseRules.level(2)
        XCTAssertEqual([two.playerSpeed, two.chaserSpeed, two.chaserFrightSpeed, two.chaserTunnelSpeed], [0.90, 0.85, 0.55, 0.45])
        XCTAssertEqual([two.elroy1Dots, two.elroy2Dots], [30, 15])
        XCTAssertEqual(two.schedule, [7, 20, 7, 20, 5, 1033, 1.0 / 60.0])
        XCTAssertEqual(two.houseDotLimits, [0, 0, 50])
        XCTAssertEqual(ChaseRules.level(3).houseDotLimits, [0, 0, 0])
        let five = ChaseRules.level(5)
        XCTAssertEqual([five.playerSpeed, five.chaserSpeed, five.chaserFrightSpeed, five.chaserTunnelSpeed], [1.0, 0.95, 0.60, 0.50])
        XCTAssertEqual([five.elroy1Speed, five.elroy2Speed], [1.00, 1.05])
        XCTAssertEqual(five.schedule, [5, 20, 5, 20, 5, 1037, 1.0 / 60.0])
        XCTAssertEqual(five.dotTimerLimit, 3)
        XCTAssertEqual(ChaseRules.level(21).playerSpeed, 0.90)
        XCTAssertEqual(ChaseRules.level(30).chaserSpeed, 0.95)
    }

    func testFrightTimesAndFlashes() {
        let times: [Double] = [6, 5, 4, 3, 2, 5, 2, 2, 1, 5, 2, 1, 1, 3, 1, 1, 0, 1, 0, 0, 0, 0]
        let flashes = [5, 5, 5, 5, 5, 5, 5, 5, 3, 5, 5, 3, 3, 5, 3, 3, 0, 3, 0, 0, 0, 0]
        for (i, t) in times.enumerated() {
            XCTAssertEqual(ChaseRules.level(i + 1).frightTime, t, "level \(i + 1)")
            XCTAssertEqual(ChaseRules.level(i + 1).frightFlashes, flashes[i], "level \(i + 1)")
        }
    }

    func testElroyThresholds() {
        let expected: [(Int, Int, Int)] = [(1, 20, 10), (2, 30, 15), (3, 40, 20), (4, 40, 20), (5, 40, 20), (6, 50, 25),
                                           (8, 50, 25), (9, 60, 30), (11, 60, 30), (12, 80, 40), (14, 80, 40),
                                           (15, 100, 50), (18, 100, 50), (19, 120, 60), (25, 120, 60)]
        for (level, one, two) in expected {
            XCTAssertEqual(ChaseRules.level(level).elroy1Dots, one, "level \(level)")
            XCTAssertEqual(ChaseRules.level(level).elroy2Dots, two, "level \(level)")
        }
    }

    func testBonusPerLevel() {
        let points = [100, 300, 500, 500, 700, 700, 1000, 1000, 2000, 2000, 3000, 3000, 5000, 5000, 5000, 5000]
        for (i, p) in points.enumerated() { XCTAssertEqual(ChaseRules.level(i + 1).bonus.points, p, "level \(i + 1)") }
        XCTAssertEqual(ChaseRules.bonusAtDots, [70, 170])
        XCTAssertEqual(Set(ChaseBonus.allCases.map(\.points)).count, 8, "eight distinct items")
    }

    func testScoringConstants() {
        XCTAssertEqual(ChaseRules.dotPoints, 10)
        XCTAssertEqual(ChaseRules.pelletPoints, 50)
        XCTAssertEqual(ChaseRules.chaserPoints, [200, 400, 800, 1600])
        XCTAssertEqual(ChaseRules.extraLifeAt, 10_000)
        XCTAssertEqual(ChaseRules.startLives, 3)
        XCTAssertEqual(ChaseRules.dotPauseFrames, 1)
        XCTAssertEqual(ChaseRules.pelletPauseFrames, 3)
        XCTAssertEqual(ChaseRules.globalRelease, [7, 17, 32])
    }

    func testModeSchedule() {
        let s = ChaseRules.level(1).schedule
        func at(_ seconds: Double) -> ChaseMode { ChaseRules.mode(afterFrames: Int(seconds * 60), schedule: s) }
        XCTAssertEqual(at(0), .scatter)
        XCTAssertEqual(at(6.98), .scatter)
        XCTAssertEqual(at(7), .chase)
        XCTAssertEqual(at(26.98), .chase)
        XCTAssertEqual(at(27), .scatter)
        XCTAssertEqual(at(34), .chase)
        XCTAssertEqual(at(54), .scatter)
        XCTAssertEqual(at(59), .chase)
        XCTAssertEqual(at(79), .scatter)
        XCTAssertEqual(at(84), .chase)
        XCTAssertEqual(at(10_000), .chase, "chase for ever")
        let two = ChaseRules.level(2).schedule
        let end = (7 + 20 + 7 + 20 + 5 + 1033) * 60
        XCTAssertEqual(ChaseRules.mode(afterFrames: end, schedule: two), .scatter, "a one-frame scatter")
        XCTAssertEqual(ChaseRules.mode(afterFrames: end + 1, schedule: two), .chase)
    }
}

final class ChaseTargetTests: XCTestCase {
    private let player = Point(x: 10, y: 20)

    private func target(_ k: ChaserKind, _ mode: ChaseMode = .chase, dir: Direction = .left,
                        red: Point = Point(x: 0, y: 0), own: Point = Point(x: 0, y: 0), elroy: Int = 0) -> Point {
        PlatyChase.target(kind: k, mode: mode, player: player, playerDir: dir, chaserTile: red, own: own, elroy: elroy)
    }

    func testDirectChaser() {
        XCTAssertEqual(target(.chaser), player)
        XCTAssertEqual(target(.chaser, .scatter), Point(x: 25, y: -3))
        XCTAssertEqual(target(.chaser, .scatter, elroy: 1), player, "Elroy keeps chasing in scatter")
    }

    func testAmbusherFourAhead() {
        XCTAssertEqual(target(.ambusher, dir: .left), Point(x: 6, y: 20))
        XCTAssertEqual(target(.ambusher, dir: .right), Point(x: 14, y: 20))
        XCTAssertEqual(target(.ambusher, dir: .down), Point(x: 10, y: 24))
        XCTAssertEqual(target(.ambusher, dir: .up), Point(x: 6, y: 16), "the arcade's up-and-left quirk")
        XCTAssertEqual(target(.ambusher, .scatter), Point(x: 2, y: -3))
        XCTAssertEqual(target(.ambusher, .scatter, elroy: 2), Point(x: 2, y: -3), "only the direct chaser is Elroy")
    }

    func testFlankerDoublesTheVector() {
        // Two ahead of the player (left): (8, 20). From the chaser at (12, 16): (8,20)*2 − (12,16) = (4, 24).
        XCTAssertEqual(target(.flanker, dir: .left, red: Point(x: 12, y: 16)), Point(x: 4, y: 24))
        // Facing up: two ahead is (8, 18) (the quirk); from (8, 10): (8, 26).
        XCTAssertEqual(target(.flanker, dir: .up, red: Point(x: 8, y: 10)), Point(x: 8, y: 26))
        XCTAssertEqual(target(.flanker, .scatter), Point(x: 27, y: 32))
    }

    func testShyChasesFarRetreatsNear() {
        XCTAssertEqual(target(.shy, own: Point(x: 10, y: 12)), player, "8 tiles away: chases")
        XCTAssertEqual(target(.shy, own: Point(x: 10, y: 13)), Point(x: 0, y: 32), "7 tiles away: its corner")
        XCTAssertEqual(target(.shy, own: Point(x: 16, y: 26)), player, "√72 > 8")
        XCTAssertEqual(target(.shy, own: Point(x: 15, y: 25)), Point(x: 0, y: 32), "√50 < 8")
        XCTAssertEqual(target(.shy, .scatter, own: Point(x: 30, y: 0)), Point(x: 0, y: 32))
    }

    func testChoiceTieBreakAndNoReverse() {
        let all: (Direction) -> Bool = { _ in true }
        // Target straight below a tile heading left: down wins.
        XCTAssertEqual(PlatyChase.choose(from: Point(x: 5, y: 5), heading: .left, target: Point(x: 5, y: 20), allowed: all), .down)
        // Equal distances (target far right, heading right): up, down and right tie only if
        // equal; here up and down tie and right is nearer.
        XCTAssertEqual(PlatyChase.choose(from: Point(x: 5, y: 5), heading: .right, target: Point(x: 20, y: 5), allowed: all), .right)
        // Up and left equally near: up wins (order up, left, down, right).
        XCTAssertEqual(PlatyChase.choose(from: Point(x: 5, y: 5), heading: .up, target: Point(x: 4, y: 4), allowed: all), .up)
        XCTAssertEqual(PlatyChase.choose(from: Point(x: 5, y: 5), heading: .right, target: Point(x: 4, y: 6), allowed: all), .down,
                       "left would be a reversal; down and up: down is nearer")
        // Never reverses, even when the target is behind.
        XCTAssertNotEqual(PlatyChase.choose(from: Point(x: 5, y: 5), heading: .right, target: Point(x: 0, y: 5), allowed: all), .left)
    }
}

final class PlatyChaseTests: XCTestCase {
    private func playing(seed: UInt64 = 1) -> PlatyChase {
        var g = PlatyChase(seed: seed)
        g.skipReady()
        return g
    }

    private func run(_ g: inout PlatyChase, _ n: Int) {
        for _ in 0..<n { g.frame() }
    }

    /// Chasers out of the way (back in the house, never let out: no dots, timer far off).
    private func clearChasers(_ g: inout PlatyChase) {
        for k in ChaserKind.allCases {
            g.setChaser(Chaser(kind: k, x: 14, y: 14.5, dir: .up, state: .home))
        }
    }

    func testStartsReadyThenPlays() {
        var g = PlatyChase(seed: 1)
        XCTAssertEqual(g.phase, .ready)
        XCTAssertEqual(g.lives, 3)
        run(&g, 119)
        XCTAssertEqual(g.phase, .ready)
        XCTAssertEqual(g.playerX, 14, "nothing moves while Ready shows")
        run(&g, 1)
        XCTAssertEqual(g.phase, .playing)
    }

    func testPlayerSpeedAndDotPause() {
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 20.5, y: 29.5, dir: .left)   // row 29: dots all along
        let step = 0.80 * ChaseRules.maxSpeed / 60
        g.frame()
        XCTAssertEqual(g.playerX, 20.5 - step, accuracy: 1e-9)
        XCTAssertEqual(g.score, 10, "the dot under it")
    }

    func testEatingADotPausesOneFrame() {
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 20.05, y: 29.5, dir: .left)
        g.frame()   // crosses into tile 19: eats its dot
        XCTAssertEqual(g.score, 10)
        let x = g.playerX
        g.frame()
        XCTAssertEqual(g.playerX, x, "one frame's pause for a dot")
        g.frame()
        XCTAssertLessThan(g.playerX, x)
    }

    func testPreTurnCutsTheCorner() {
        var g = playing()
        clearChasers(&g)
        // Row 4, moving left towards the junction at column 5 (up is open), before its centre.
        g.placePlayer(x: 5.8, y: 4.5, dir: .left)
        g.turn(.up)
        g.frame()
        XCTAssertEqual(g.playerDir, .up, "turned before reaching the centre")
        XCTAssertLessThan(g.playerY, 4.5, "already going up")
        XCTAssertLessThan(g.playerX, 5.8, "and closing on the centre line: a diagonal")
        run(&g, 6)
        XCTAssertEqual(g.playerX, 5.5, accuracy: 1e-9, "aligned on the new corridor")
    }

    func testPostTurnWindowAndBuffering() {
        // Moving left or up: 4 pixels before the centre, 3 after; right or down: 3 and 4.
        XCTAssertTrue(PlatyChase.cornerAllowed(pastCentre: -0.5, moving: .left))
        XCTAssertTrue(PlatyChase.cornerAllowed(pastCentre: 0.375, moving: .left))
        XCTAssertFalse(PlatyChase.cornerAllowed(pastCentre: 0.4, moving: .up))
        XCTAssertFalse(PlatyChase.cornerAllowed(pastCentre: -0.4, moving: .right))
        XCTAssertTrue(PlatyChase.cornerAllowed(pastCentre: -0.375, moving: .right))
        XCTAssertTrue(PlatyChase.cornerAllowed(pastCentre: 0.49, moving: .down))
        XCTAssertEqual(ChaseRules.cornerWindow(.right).pre * 8, 3)
        XCTAssertEqual(ChaseRules.cornerWindow(.left).pre * 8, 4)
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 5.2, y: 4.5, dir: .left)   // 0.3 past the centre: still turns
        g.turn(.up)
        g.frame()
        XCTAssertEqual(g.playerDir, .up)
        var late = playing()
        clearChasers(&late)
        late.placePlayer(x: 5.05, y: 4.5, dir: .left)   // 0.45 past: too late here
        late.turn(.up)
        late.frame()
        XCTAssertEqual(late.playerDir, .left, "kept going")
        var frames = 0
        while late.playerDir == .left, frames < 300 {
            late.frame()
            frames += 1
        }
        XCTAssertEqual(late.playerDir, .up, "the buffered turn is taken at the next opening")
        XCTAssertEqual(late.playerTile.x, 1, "column 1, the next way up")
    }

    func testStopsAtAWall() {
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 3.5, y: 4.5, dir: .left)
        run(&g, 60)
        XCTAssertEqual(g.playerX, 1.5, accuracy: 1e-9)
        XCTAssertFalse(g.playerMoving)
    }

    func testTunnelWrapsAndSlowsChasers() {
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 1.5, y: 14.5, dir: .left)
        run(&g, 20)
        XCTAssertGreaterThan(g.playerX, 25, "came out on the right")
        XCTAssertEqual(g.playerTile.y, 14)
        var h = playing()
        h.placePlayer(x: 14, y: 23.5, dir: .left, moving: false)
        h.setChaser(Chaser(kind: .chaser, x: 3.4, y: 14.5, dir: .left, state: .active))
        h.frame()
        let red = h.chasers[0]
        XCTAssertEqual(3.4 - red.x, 0.40 * ChaseRules.maxSpeed / 60, accuracy: 1e-9, "tunnel speed")
    }

    func testFrightenedModeScoresAndFlashes() {
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 1.5, y: 3.9, dir: .up)   // on the pellet's tile (1, 3)
        var n = 0
        while g.frightFrames == 0, n < 30 {
            g.frame()
            n += 1
        }
        XCTAssertEqual(g.score, 50)
        XCTAssertEqual(g.frightFrames, 6 * 60)
        XCTAssertTrue(g.chasers.allSatisfy(\.frightened), "even those at home turn blue")
        XCTAssertFalse(g.frightFlashing)
        // Eat four in a row: 200, 400, 800, 1600.
        var expected = 50
        for (i, k) in ChaserKind.allCases.enumerated() {
            g.placePlayer(x: 1.5, y: 1.5, dir: .left, moving: false)
            var c = Chaser(kind: k, x: 1.5, y: 1.5, dir: .left, state: .active)
            c.frightened = true
            g.setChaser(c)
            g.frame()
            expected += ChaseRules.chaserPoints[i]
            XCTAssertEqual(g.score, expected)
            XCTAssertEqual(g.phase, .chaserEaten)
            XCTAssertEqual(g.chasers.first { $0.kind == k }?.state, .eyes)
            run(&g, 60)
            XCTAssertEqual(g.phase, .playing, "the freeze lasts one second")
        }
    }

    func testFlashesAtTheEndOfAFright() {
        XCTAssertFalse(PlatyChase.flashing(frightFrames: 71, flashes: 5))
        XCTAssertTrue(PlatyChase.flashing(frightFrames: 70, flashes: 5), "5 flashes of 14 frames")
        XCTAssertTrue(PlatyChase.flashing(frightFrames: 1, flashes: 5))
        XCTAssertFalse(PlatyChase.flashing(frightFrames: 0, flashes: 5))
        XCTAssertFalse(PlatyChase.flashing(frightFrames: 43, flashes: 3))
        XCTAssertTrue(PlatyChase.flashing(frightFrames: 42, flashes: 3))
        let whites = (1...70).filter { PlatyChase.white(frightFrames: $0, flashes: 5) }.count
        XCTAssertEqual(whites, 35, "half of each flash is white")
        XCTAssertFalse(PlatyChase.white(frightFrames: 7, flashes: 5))
        XCTAssertTrue(PlatyChase.white(frightFrames: 8, flashes: 5))
    }

    func testFrightEndsAndChasersReturnToNormal() {
        var g = playing()
        clearChasers(&g)
        g.placePlayer(x: 1.5, y: 3.9, dir: .up)
        g.frame()
        XCTAssertEqual(g.frightFrames, 360)
        var n = 0
        while g.frightFrames > 0, g.phase == .playing || g.phase == .chaserEaten, n < 2000 {
            g.frame()
            n += 1
        }
        XCTAssertEqual(g.frightFrames, 0)
        XCTAssertFalse(g.chasers.contains(where: \.frightened))
    }

    func testReversalWaitsForTheNextTile() {
        var g = playing()
        g.placePlayer(x: 14, y: 23.5, dir: .left, moving: false)
        g.setChaser(Chaser(kind: .chaser, x: 21.6, y: 4.5, dir: .right, state: .active))   // 0.1 past the centre
        g.placePlayer(x: 1.5, y: 3.9, dir: .up)   // eats the pellet: a reversal is signalled
        g.frame()
        let red = g.chasers[0]
        XCTAssertEqual(g.lastReversal, g.frames)
        XCTAssertEqual(red.dir, .right, "not yet: still in its tile")
        XCTAssertTrue(red.reversePending)
        var n = 0
        while g.chasers[0].dir == .right, n < 20 {
            g.frame()
            n += 1
        }
        XCTAssertEqual(g.chasers[0].dir, .left)
        XCTAssertEqual(g.chasers[0].x, 22, accuracy: 0.2, "turned round at the edge of tile 22")
    }

    func testPelletReversesChasersAndLevelSeventeenHasNoBlue() {
        var g = PlatyChase(seed: 3, level: 17)
        g.skipReady()
        g.placePlayer(x: 1.5, y: 3.9, dir: .up)
        g.setChaser(Chaser(kind: .chaser, x: 20.5, y: 29.5, dir: .left, state: .active))
        while g.score < 50 { g.frame() }
        XCTAssertEqual(g.frightFrames, 0)
        XCTAssertFalse(g.chasers.contains(where: \.frightened))
        XCTAssertEqual(g.lastReversal, g.frames, "still a reversal")
    }

    func testCaughtLosesALifeThenGameOver() {
        var g = playing()
        for life in (1...3).reversed() {
            g.skipReady()
            g.setChaser(Chaser(kind: .chaser, x: g.playerX, y: g.playerY, dir: .left, state: .active))
            g.frame()
            XCTAssertEqual(g.phase, .dying)
            run(&g, 149)
            XCTAssertEqual(g.phase, .dying, "a 1 s freeze and a 1.5 s death")
            g.frame()
            XCTAssertEqual(g.lives, life - 1)
            if life > 1 {
                XCTAssertEqual(g.phase, .ready)
                XCTAssertEqual(g.playerX, ChaseMaze.playerStart.x)
            }
        }
        XCTAssertTrue(g.isOver)
        XCTAssertEqual(g.phase, .over)
    }

    func testExtraLifeAtTenThousandOnce() {
        var g = playing()
        g.addPoints(9_990)
        XCTAssertEqual(g.lives, 3)
        g.addPoints(10)
        XCTAssertEqual(g.lives, 4)
        g.addPoints(20_000)
        XCTAssertEqual(g.lives, 4)
    }

    func testBonusAtSeventyAndOneSeventy() {
        var g = playing()
        for _ in 0..<69 { g.simulateDotEaten() }
        XCTAssertNil(g.bonus)
        g.simulateDotEaten()
        let b = try? XCTUnwrap(g.bonus)
        XCTAssertEqual(b?.kind, .shrimp)
        XCTAssertTrue((540...600).contains(b?.framesLeft ?? 0), "9 to 10 seconds")
        var h = PlatyChase(seed: 1, level: 7)
        for _ in 0..<170 { h.simulateDotEaten() }
        XCTAssertEqual(h.bonus?.kind.points, 1000)
    }

    func testGhostHouseRelease() {
        var g = playing()
        g.placePlayer(x: 14, y: 23.5, dir: .left, moving: false)
        g.frame()
        XCTAssertEqual(g.chasers[1].state, .leaving, "the ambusher's limit is 0")
        XCTAssertEqual(g.chasers[2].state, .home)
        for _ in 0..<29 { g.simulateDotEaten() }
        g.frame()
        XCTAssertEqual(g.chasers[2].state, .home, "29 of 30")
        g.simulateDotEaten()
        g.frame()
        XCTAssertEqual(g.chasers[2].state, .leaving, "the flanker leaves at 30")
        XCTAssertEqual(g.chasers[3].state, .home)
        // No dot for 4 seconds: the shy one is let out by the timer.
        run(&g, 238)
        XCTAssertEqual(g.chasers[3].state, .home)
        g.frame()
        XCTAssertEqual(g.chasers[3].state, .leaving)
    }

    func testGlobalCounterAfterALostLife() {
        var g = playing()
        g.setChaser(Chaser(kind: .chaser, x: g.playerX, y: g.playerY, dir: .left, state: .active))
        g.frame()
        run(&g, 150)
        XCTAssertEqual(g.phase, .ready)
        g.skipReady()
        g.placePlayer(x: 14, y: 23.5, dir: .left, moving: false)
        for _ in 0..<6 { g.simulateDotEaten() }
        g.frame()
        XCTAssertEqual(g.chasers[1].state, .home, "6 of 7")
        g.simulateDotEaten()
        XCTAssertEqual(g.chasers[1].state, .leaving, "7: the ambusher")
        for _ in 0..<10 { g.simulateDotEaten() }
        XCTAssertEqual(g.chasers[2].state, .leaving, "17: the flanker")
        for _ in 0..<14 { g.simulateDotEaten() }
        XCTAssertEqual(g.chasers[3].state, .home)
        XCTAssertEqual(g.elroy, 0)
        g.simulateDotEaten()
        XCTAssertEqual(g.chasers[3].state, .leaving, "32: the shy one")
    }

    func testElroy() {
        var g = playing()
        g.clearFood(keeping: 21)
        XCTAssertEqual(g.elroy, 0)
        g.clearFood(keeping: 20)
        XCTAssertEqual(g.elroy, 1)
        g.clearFood(keeping: 10)
        XCTAssertEqual(g.elroy, 2)
        g.placePlayer(x: 14, y: 23.5, dir: .left, moving: false)
        g.setChaser(Chaser(kind: .chaser, x: 21.5, y: 4.5, dir: .left, state: .active))   // not in the tunnel
        g.frame()
        let moved = 21.5 - g.chasers[0].x
        XCTAssertEqual(moved, 0.85 * ChaseRules.maxSpeed / 60, accuracy: 1e-9, "Elroy 2 at level 1: 85%")
    }

    func testLastDotClearsTheLevel() {
        var g = playing()
        clearChasers(&g)
        g.clearFood(keeping: 1)
        // The one dot kept is the first in reading order: (1, 1).
        g.placePlayer(x: 3.5, y: 1.5, dir: .left)
        var n = 0
        while g.phase == .playing, n < 100 {
            g.frame()
            n += 1
        }
        XCTAssertEqual(g.phase, .levelClear)
        run(&g, 120)
        XCTAssertEqual(g.level.number, 2)
        XCTAssertEqual(g.dotsLeft, 244)
        XCTAssertEqual(g.phase, .ready)
    }

    /// Chasers never turn back on their own: every reversal seen was signalled by a mode
    /// change or power pellet, and happens as the chaser enters its next tile.
    func testNoReversalExceptOnAModeChange() {
        var g = playing(seed: 9)
        var rng = SeededRNG(seed: 4)
        var reversals = 0
        for i in 0..<6000 where !g.isOver {
            if i % 25 == 0 { g.turn(Direction.allCases[rng.below(4)]) }
            let before = g.chasers
            g.frame()
            for (a, b) in zip(before, g.chasers) where a.state == .active && b.state == .active && b.dir == a.dir.opposite {
                XCTAssertTrue(a.reversePending || g.lastReversal == g.frames, "\(b.kind) reversed unasked on frame \(g.frames)")
                XCTAssertFalse(b.reversePending)
                let along = b.dir.dx != 0 ? b.x : b.y
                XCTAssertLessThan(abs(along - along.rounded()), 0.3, "turned round near a tile edge")
                reversals += 1
            }
        }
        XCTAssertGreaterThan(reversals, 0, "mode changes did reverse them")
    }

    func testDeterministic() {
        func play(_ seed: UInt64) -> PlatyChase {
            var g = PlatyChase(seed: seed)
            var rng = SeededRNG(seed: seed)
            for i in 0..<4000 where !g.isOver {
                if i % 30 == 0 { g.turn(Direction.allCases[rng.below(4)]) }
                g.frame()
            }
            return g
        }
        XCTAssertEqual(play(5), play(5))
        XCTAssertNotEqual(play(5), play(6))
    }

    func testSessionPlaysChase() {
        var s = GameSession(kind: .chase, seed: 2)
        s.setBlockers(GameBlockers())
        XCTAssertTrue(s.key(.space))
        XCTAssertTrue(s.isRunning)
        XCTAssertTrue(s.key(.up))
        XCTAssertEqual(s.chase.wanted, .up)
        s.advance(to: 0)
        s.advance(to: 0.201)
        XCTAssertEqual(s.chase.frames, 12)
        XCTAssertEqual(GameKind.chase.title, "Platy Chase")
    }
}
