import AppKit
import PlatyNotchKit
import SwiftUI

/// `--platy-gallery <dir>` also writes `<dir>/games/*.png`: every game drawn by the app's
/// own views in several states (start, mid-game, mid-animation frames, game over) on the
/// panel's surface, at the board area's size and 2x. No window, no frames, no saving.
@MainActor
enum GameRenders {
    /// Writes the game renders; returns how many.
    static func write(to dir: URL) throws -> Int {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var count = 0
        for (name, view) in shots() {
            for scheme in [ColorScheme.dark, .light] where scheme == .dark || name.hasSuffix("-play") {
                let suffix = scheme == .dark ? "" : "-light"
                let framed = GameShotFrame(content: view).environment(\.colorScheme, scheme)
                guard let data = PlatyRenders.png(framed, scale: 2) else {
                    throw PlatyRenders.Failure(message: "\(name) did not render")
                }
                let url = dir.appendingPathComponent("\(name)\(suffix).png")
                do { try data.write(to: url) } catch { throw PlatyRenders.Failure(message: "cannot write \(url.path)") }
                count += 1
            }
        }
        return count
    }

    private static func shots() -> [(String, AnyView)] {
        flappyShots() + game2048Shots() + tetrisShots() + snakeShots() + chaseShots()
    }

    private static func card(_ title: String, _ detail: String) -> AnyView {
        AnyView(GameOverlayCard(title: title, detail: detail))
    }

    // MARK: - Flappy

    /// Flies a simple pilot for `seconds` (the same rule as the engine test).
    private static func flown(seed: UInt64, seconds: Double, pilot: Bool = true) -> Flappy {
        var f = Flappy(seed: seed)
        let steps = Int(seconds * 120)
        for _ in 0..<steps where !f.isOver {
            let next = f.pipes.first { $0.x + Flappy.pipeWidth >= Flappy.birdX - Flappy.birdRadius }
            let target: Double = (next?.gapY ?? Flappy.height / 2) + 18
            if pilot, f.birdY > target, f.velocity > 0 { f.flap() }
            f.step(dt: 1.0 / 120.0)
        }
        return f
    }

    private static func untilWing(_ start: Flappy, _ wing: Flappy.Wing) -> Flappy {
        var f = start
        var n = 0
        while f.wing != wing, n < 200 {
            f.step(dt: 1.0 / 240.0)
            n += 1
        }
        return f
    }

    private static func flappyShots() -> [(String, AnyView)] {
        let start = Flappy(seed: 7)
        let mid = flown(seed: 7, seconds: 9)
        let up = untilWing(mid, .up)
        let down = untilWing(up, .down)
        var dive = untilWing(down, .middle)
        dive.velocity = Flappy.maxFallSpeed
        var over = flown(seed: 7, seconds: 9)
        while !over.isOver { over.step(dt: 1.0 / 120.0) }
        func view(_ f: Flappy, _ overlay: AnyView? = nil) -> AnyView {
            AnyView(ZStack { FlappyView(flappy: f, decorate: true); overlay })
        }
        return [
            ("flappy-1-start", view(start, card("Press Space", GameKind.flappy.help))),
            ("flappy-2-wing-up-play", view(up)),
            ("flappy-3-wing-down", view(down)),
            ("flappy-4-dive", view(dive)),
            ("flappy-5-over", view(over, card("Game over · \(over.score)", "Press Space to play again"))),
            ("flappy-6-reduce-motion", AnyView(FlappyView(flappy: dive, decorate: false))),
            ("flappy-bird-zoom", AnyView(FlappyBirdSheet())),
        ]
    }

    // MARK: - 2048

    private static func game2048Shots() -> [(String, AnyView)] {
        let grid = [[2, 2, 4, 0], [0, 4, 0, 4], [8, 0, 8, 16], [0, 32, 2, 2]]
        var g = Game2048(grid: grid, seed: 5)
        let before = g
        g.move(.left)
        var shots: [(String, AnyView)] = [("2048-0-before", AnyView(Game2048Canvas(game: before, progress: 1)))]
        let frames: [(String, Double)] = [("a-slide-25", 0.11), ("b-slide-60", 0.27), ("c-pop", 0.6), ("d-settle", 0.85), ("e-done-play", 1)]
        for (label, p) in frames {
            shots.append(("2048-1-\(label)", AnyView(Game2048Canvas(game: g, progress: p))))
        }
        var big = Game2048(grid: [[2, 4, 8, 16], [32, 64, 128, 256], [512, 1024, 2048, 4], [0, 0, 2, 0]], seed: 2)
        big.move(.down)
        shots.append(("2048-2-colours", AnyView(Game2048Canvas(game: big, progress: 1))))
        return shots
    }

    // MARK: - Tetris

    private static func tetrisShots() -> [(String, AnyView)] {
        var board = Array(repeating: Array(repeating: 0, count: 10), count: 20)
        let rows: [[Int]] = [
            [3, 3, 0, 5, 5, 6, 6, 6, 0, 1],
            [3, 2, 2, 5, 4, 4, 6, 7, 7, 1],
            [1, 2, 2, 4, 4, 0, 7, 7, 3, 1],
            [1, 6, 6, 6, 0, 0, 5, 5, 3, 1],
        ]
        for (i, r) in rows.enumerated() { board[16 + i] = r }
        board[15] = [0, 0, 0, 0, 0, 0, 0, 2, 2, 0]
        let falling = Tetris(board: board, piece: TetrisPiece(kind: .t, rotation: 2, x: 3, y: 3), queue: [.l, .i, .s])
        let low = Tetris(board: board, piece: TetrisPiece(kind: .j, rotation: 1, x: 3, y: 10), queue: [.o, .z, .t])
        var fresh = Tetris(seed: 3)
        fresh.score = 0
        return [
            ("tetris-1-start", AnyView(ZStack { TetrisView(tetris: fresh); card("Press Space", GameKind.tetris.help) })),
            ("tetris-2-falling-play", AnyView(TetrisView(tetris: falling))),
            ("tetris-3-near-bottom", AnyView(TetrisView(tetris: low))),
        ]
    }

    // MARK: - Snake

    private static func snakeShots() -> [(String, AnyView)] {
        var alive = Snake(seed: 4)
        alive.body = [Point(x: 12, y: 3), Point(x: 11, y: 3), Point(x: 10, y: 3), Point(x: 10, y: 4), Point(x: 10, y: 5),
                      Point(x: 11, y: 5), Point(x: 12, y: 5), Point(x: 13, y: 5), Point(x: 14, y: 5), Point(x: 15, y: 5)]
        alive.food = Point(x: 18, y: 2)
        alive.score = 7
        var dead = alive
        dead.turn(.down)
        dead.step()
        dead.step()   // (12,4) then into (12,5): itself
        var wall = Snake(seed: 4)
        wall.food = Point(x: 0, y: 0)
        while !wall.isOver { wall.step() }
        var shots: [(String, AnyView)] = [
            ("snake-1-start", AnyView(ZStack { SnakeCanvas(snake: Snake(seed: 4), pulse: 0, death: 0); card("Press Space", GameKind.snake.help) })),
            ("snake-2-mid-play", AnyView(SnakeCanvas(snake: alive, pulse: 0.5, death: 0))),
        ]
        let frames: [(String, Double)] = [("a-flash", 0.04), ("b-blink-off", 0.1), ("c-flash-ring", 0.2), ("d-fade-head", 0.45),
                                          ("e-fade-mid", 0.65), ("f-faded", 1)]
        for (label, p) in frames {
            shots.append(("snake-3-self-\(label)", AnyView(SnakeCanvas(snake: dead, pulse: 0, death: p))))
        }
        shots.append(("snake-4-wall-flash", AnyView(SnakeCanvas(snake: wall, pulse: 0, death: 0.2))))
        shots.append(("snake-5-over", AnyView(ZStack {
            SnakeCanvas(snake: dead, pulse: 0, death: 1)
            card("Game over · \(dead.score)", "Press Space to play again")
        })))
        return shots
    }
}

extension GameRenders {
    /// Plays with turns from a seeded generator until `frames` (or a lost life).
    private static func played(seed: UInt64, frames: Int) -> PlatyChase {
        var g = PlatyChase(seed: seed)
        var rng = SeededRNG(seed: seed)
        for i in 0..<frames where g.phase != .dying && !g.isOver {
            if i % 24 == 0 { g.turn(Direction.allCases[rng.below(4)]) }
            g.frame()
        }
        return g
    }

    static func chaseShots() -> [(String, AnyView)] {
        func view(_ g: PlatyChase, _ overlay: AnyView? = nil) -> AnyView {
            AnyView(ZStack { ChaseView(game: g, decorate: true); overlay })
        }
        let start = PlatyChase(seed: 2)
        // The first seed whose random pilot is still alive after 12 s.
        var mid = played(seed: 1, frames: 720)
        for seed: UInt64 in 2...60 where mid.phase != .playing { mid = played(seed: seed, frames: 720) }
        var fright = mid
        fright.placePlayer(x: 26.5, y: 3.9, dir: .up)
        for _ in 0..<40 { fright.frame() }
        var flash = fright
        while flash.frightFrames > 40, flash.phase == .playing || flash.phase == .chaserEaten { flash.frame() }
        while !flash.flashWhite, flash.frightFrames > 1 { flash.frame() }
        var eaten = fright
        if let blue = eaten.chasers.first(where: { $0.frightened && $0.state == .active }) {
            eaten.placePlayer(x: blue.x, y: blue.y, dir: eaten.playerDir, moving: false)
            eaten.frame()
            for _ in 0..<45 { eaten.frame() }
        }
        var eyes = eaten
        for _ in 0..<40 { eyes.frame() }
        var bonus = mid
        while bonus.bonus == nil, bonus.dotsEaten < 70 { bonus.simulateDotEaten() }
        var dying = mid
        dying.setChaser(Chaser(kind: .chaser, x: dying.playerX, y: dying.playerY, dir: .left, state: .active))
        dying.frame()
        var dyingFrozen = dying
        for _ in 0..<30 { dyingFrozen.frame() }
        for _ in 0..<(60 + 55) { dying.frame() }
        return [
            ("chase-1-start", view(start, AnyView(GameOverlayCard(title: "Press Space", detail: GameKind.chase.help)))),
            ("chase-2-ready", view(start)),
            ("chase-3-mid-play", view(mid)),
            ("chase-4-frightened", view(fright)),
            ("chase-5-flashing", view(flash)),
            ("chase-6-eaten-points", view(eaten)),
            ("chase-6b-eyes-home", view(eyes)),
            ("chase-7-bonus", view(bonus)),
            ("chase-8-caught-freeze", view(dyingFrozen)),
            ("chase-9-death", view(dying)),
            ("chase-art-sheet", AnyView(ChaseArtSheet())),
        ]
    }
}

/// The creatures, Platy and the snacks, big: the art check.
private struct ChaseArtSheet: View {
    var body: some View {
        Canvas { ctx, _ in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 520, height: 250)), with: .color(ChaseArt.background))
            var big = ctx
            big.scaleBy(x: 26, y: 26)
            for (i, k) in ChaserKind.allCases.enumerated() {
                ChaseArt.drawCreature(k, in: big, at: CGPoint(x: 1.2 + Double(i) * 2.2, y: 1.6), dir: .right, wiggle: i % 2 == 0)
            }
            ChaseArt.drawPlaty(in: big, at: CGPoint(x: 10.4, y: 1.6), tile: 1, dir: .right, open: 0.9)
            ChaseArt.drawPlaty(in: big, at: CGPoint(x: 12.6, y: 1.6), tile: 1, dir: .up, open: 0.1)
            ChaseArt.drawPlaty(in: big, at: CGPoint(x: 14.8, y: 1.6), tile: 1, dir: .left, open: 0.5)
            for (i, b) in ChaseBonus.allCases.enumerated() {
                ChaseArt.drawBonus(b, in: big, at: CGPoint(x: 1.2 + Double(i) * 2.1, y: 4.3), tile: 1)
            }
            var real = ctx
            real.scaleBy(x: GameLayout.chaseTile, y: GameLayout.chaseTile)
            for (i, k) in ChaserKind.allCases.enumerated() {
                ChaseArt.drawCreature(k, in: real, at: CGPoint(x: 3 + Double(i) * 3, y: 27), dir: .left, wiggle: false)
            }
            ChaseArt.drawPlaty(in: real, at: CGPoint(x: 16, y: 27), tile: 1, dir: .left, open: 0.6)
            for (i, b) in ChaseBonus.allCases.enumerated() {
                ChaseArt.drawBonus(b, in: real, at: CGPoint(x: 21 + Double(i) * 3, y: 27), tile: 1)
            }
        }
        .frame(width: 520, height: 250)
    }
}

/// A board on the panel's surface, at the board area's size.
private struct GameShotFrame: View {
    let content: AnyView
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(width: GameLayout.boardArea.width, height: GameLayout.boardArea.height)
            .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 10))
            .padding(12)
            .background(Theme.surface(scheme))
    }
}

/// The bird alone, big, in each wing pose and tilt: the art check.
private struct FlappyBirdSheet: View {
    var body: some View {
        Canvas { ctx, _ in
            let poses: [(Flappy.Wing, Double)] = [(.up, -22), (.middle, -22), (.down, -22), (.middle, 20), (.middle, 70)]
            ctx.fill(Path(CGRect(x: 0, y: 0, width: 520, height: 140)), with: .color(FlappyArt.skyBottom))
            for (i, pose) in poses.enumerated() {
                var c = ctx
                c.scaleBy(x: 2.4, y: 2.4)
                let x: Double = 22 + Double(i) * 43
                FlappyArt.drawBird(in: c, at: CGPoint(x: x, y: 26), tilt: pose.1, wing: pose.0)
            }
            // Real size (as in the game).
            var real = ctx
            real.scaleBy(x: GameLayout.flappyScale, y: GameLayout.flappyScale)
            for (i, pose) in poses.enumerated() {
                let x: Double = (40 + Double(i) * 104) / GameLayout.flappyScale
                FlappyArt.drawBird(in: real, at: CGPoint(x: x, y: 122 / GameLayout.flappyScale), tilt: pose.1, wing: pose.0)
            }
        }
        .frame(width: 520, height: 140)
    }
}
