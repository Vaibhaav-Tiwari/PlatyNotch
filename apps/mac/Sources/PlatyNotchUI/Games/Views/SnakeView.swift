import PlatyNotchKit
import SwiftUI

/// Colors shared by the boards.
enum GameColors {
    static let board = Color.primary.opacity(0.05)
    static let grid = Color.primary.opacity(0.03)
    static let well = Color.primary.opacity(0.06)
    static let wellEdge = Color.primary.opacity(0.12)
    static let gridLine = Color.primary.opacity(0.07)
    static let accent = Color(nsColor: .systemGreen)
    /// The snake's body: a deeper, opaque green than its head.
    static let body = Color(red: 0.16, green: 0.66, blue: 0.33)
    static let food = Color(nsColor: .systemRed)
    static let crash = Color(nsColor: .systemRed)
}

/// The Snake board: a 24 × 8 grid of `GameLayout.snakeCell` points. When the snake dies a
/// one-second SwiftUI keyframe animation plays (only then: no frames otherwise): the
/// crash point flashes and the head blinks, then the body fades segment by segment from
/// head to tail; the game-over card waits for it (`GamesTab`). Reduce Motion shows the
/// final, faded state at once.
struct SnakeView: View {
    let snake: Snake
    /// 0…1: the food's gentle pulse (always 0 with Reduce Motion).
    let pulse: Double
    /// The death animation (false with Reduce Motion).
    let animate: Bool

    var body: some View {
        let size = GameLayout.boardSize(.snake)
        Group {
            if animate {
                Color.clear
                    .keyframeAnimator(initialValue: 1.0, trigger: snake.isOver) { _, progress in
                        SnakeCanvas(snake: snake, pulse: pulse, death: snake.isOver ? progress : 0)
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(0.0)
                            LinearKeyframe(1.0, duration: SnakeCanvas.deathDuration)
                        }
                    }
            } else {
                SnakeCanvas(snake: snake, pulse: pulse, death: snake.isOver ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel("Snake, score \(snake.score)")
    }
}

/// One frame of the Snake board; `death` (0…1) is how far the death animation has run
/// (0 while alive).
struct SnakeCanvas: View {
    let snake: Snake
    let pulse: Double
    let death: Double

    static let deathDuration: Double = 1.1
    /// The flash and blink, then the fade: fractions of `deathDuration`.
    static let flashEnd: Double = 0.32
    static let fadeSpan: Double = 0.55
    static let segmentFade: Double = 0.13
    /// What is left of a faded segment.
    static let fadedOpacity: Double = 0.14

    var body: some View {
        let size = GameLayout.boardSize(.snake)
        Canvas { ctx, _ in draw(in: ctx, size: size) }
            .frame(width: size.width, height: size.height)
    }

    private func cell(_ p: PlatyNotchKit.Point) -> CGRect {
        let c: CGFloat = GameLayout.snakeCell
        return CGRect(x: CGFloat(p.x) * c, y: CGFloat(p.y) * c, width: c, height: c)
    }

    /// The join between two neighbouring segments (one body, not beads).
    private func bridge(_ a: PlatyNotchKit.Point, _ b: PlatyNotchKit.Point) -> CGRect {
        let ra = cell(a).insetBy(dx: 4, dy: 4)
        let rb = cell(b).insetBy(dx: 4, dy: 4)
        return ra.union(rb)
    }

    /// Segment `i`'s opacity during the fade (head first).
    static func segmentOpacity(_ i: Int, of n: Int, death: Double) -> Double {
        guard death > flashEnd else { return 1 }
        let start: Double = flashEnd + fadeSpan * Double(i) / Double(max(n, 1))
        let t: Double = min(max((death - start) / segmentFade, 0), 1)
        return 1 - t * (1 - fadedOpacity)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        ctx.fill(Path(roundedRect: bounds, cornerRadius: 8), with: .color(GameColors.board))
        drawCheckers(in: ctx, size: size)
        drawFood(in: ctx)
        let n = snake.body.count
        for i in stride(from: n - 1, through: 0, by: -1) {
            let p = snake.body[i]
            let opacity = Self.segmentOpacity(i, of: n, death: death)
            let r = cell(p).insetBy(dx: 1.5, dy: 1.5)
            var seg = ctx
            seg.opacity = opacity
            let color = i == 0 ? GameColors.accent : GameColors.body
            seg.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(color))
            if i + 1 < n { seg.fill(Path(bridge(p, snake.body[i + 1])), with: .color(color)) }
            if i == 0 { drawHead(in: seg, r) }
        }
        if death > 0 { drawCrash(in: ctx) }
    }

    /// A barely visible checkerboard, so the cells read.
    private func drawCheckers(in ctx: GraphicsContext, size: CGSize) {
        var p = Path()
        for y in 0..<snake.height {
            for x in 0..<snake.width where (x + y) % 2 == 0 {
                p.addRect(cell(PlatyNotchKit.Point(x: x, y: y)))
            }
        }
        ctx.fill(p, with: .color(GameColors.grid))
    }

    private func drawFood(in ctx: GraphicsContext) {
        let shrink: CGFloat = 4 - CGFloat(pulse) * 1.5
        let food = cell(snake.food).insetBy(dx: shrink, dy: shrink)
        ctx.fill(Path(ellipseIn: food), with: .color(GameColors.food))
        let shine = CGRect(x: food.minX + food.width * 0.22, y: food.minY + food.height * 0.18,
                           width: food.width * 0.28, height: food.height * 0.24)
        ctx.fill(Path(ellipseIn: shine), with: .color(.white.opacity(0.45)))
        let leaf = CGRect(x: food.midX, y: food.minY - 3, width: 5, height: 4)
        ctx.fill(Path(ellipseIn: leaf), with: .color(GameColors.accent))
    }

    /// Two eyes looking where the snake heads; closed (a line) once it has died.
    private func drawHead(in ctx: GraphicsContext, _ r: CGRect) {
        let d = snake.heading
        let ahead = CGPoint(x: r.midX + CGFloat(d.dx) * r.width * 0.18, y: r.midY + CGFloat(d.dy) * r.height * 0.18)
        let side = CGPoint(x: CGFloat(-d.dy) * r.width * 0.22, y: CGFloat(d.dx) * r.height * 0.22)
        for s in [CGFloat(1), -1] {
            let c = CGPoint(x: ahead.x + side.x * s, y: ahead.y + side.y * s)
            if death > 0 {
                var x = Path()
                x.move(to: CGPoint(x: c.x - 2, y: c.y - 2))
                x.addLine(to: CGPoint(x: c.x + 2, y: c.y + 2))
                x.move(to: CGPoint(x: c.x + 2, y: c.y - 2))
                x.addLine(to: CGPoint(x: c.x - 2, y: c.y + 2))
                ctx.stroke(x, with: .color(.black.opacity(0.7)), lineWidth: 1.4)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.6, y: c.y - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
                let pupil = CGRect(x: c.x - 1.3 + CGFloat(d.dx), y: c.y - 1.3 + CGFloat(d.dy), width: 2.6, height: 2.6)
                ctx.fill(Path(ellipseIn: pupil), with: .color(.black))
            }
        }
    }

    /// The crash: three red blinks over the hit cell with a ring bursting out of it, then
    /// a dim red mark that stays.
    private func drawCrash(in ctx: GraphicsContext) {
        guard let crash = snake.crash else { return }
        let r = cell(crash)
        let center = CGPoint(x: r.midX, y: r.midY)
        if death < Self.flashEnd {
            let t: Double = death / Self.flashEnd
            let blinkOn: Bool = Int(t * 6) % 2 == 0
            if blinkOn {
                ctx.fill(Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 5), with: .color(GameColors.crash.opacity(0.9)))
            }
            let radius: CGFloat = r.width * CGFloat(0.4 + t * 0.9)
            let ring = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            ctx.stroke(Path(ellipseIn: ring), with: .color(GameColors.crash.opacity(1 - t)), lineWidth: 2.5)
        } else {
            ctx.stroke(Path(roundedRect: r.insetBy(dx: 2, dy: 2), cornerRadius: 5),
                       with: .color(GameColors.crash.opacity(0.75)), lineWidth: 2)
        }
    }
}
