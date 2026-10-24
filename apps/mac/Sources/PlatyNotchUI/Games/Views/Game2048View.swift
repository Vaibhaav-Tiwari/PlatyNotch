import PlatyNotchKit
import SwiftUI

/// The 2048 grid: 4 × 4 tiles of `GameLayout.tile` points. Turn-based: nothing draws
/// between moves. A move plays a short SwiftUI keyframe animation driven by the engine's
/// `lastMove`: tiles slide from their old cell to their new one (110 ms, eased), then
/// merged tiles pop and the new tile scales in. A key pressed mid-animation is applied
/// by the engine at once and restarts the animation from the grid it left (the old one
/// is finished instantly), so no move is ever dropped or applied twice. With Reduce
/// Motion the grid snaps to its final state.
struct Game2048View: View {
    let game: Game2048
    /// Slide and pop (false with Reduce Motion).
    let animate: Bool

    var body: some View {
        let size = GameLayout.boardSize(.twenty48)
        Group {
            if animate {
                Color.clear
                    .keyframeAnimator(initialValue: 1.0, trigger: game.lastMove?.serial ?? 0) { _, progress in
                        Game2048Canvas(game: game, progress: progress)
                    } keyframes: { _ in
                        KeyframeTrack {
                            MoveKeyframe(0.0)
                            LinearKeyframe(1.0, duration: Game2048Canvas.duration)
                        }
                    }
            } else {
                Game2048Canvas(game: game, progress: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityLabel("2048, score \(game.score)")
    }
}

/// One frame of the 2048 grid, `progress` (0…1) through the last move's animation.
struct Game2048Canvas: View {
    let game: Game2048
    let progress: Double

    /// The whole animation: the slide, then the pop and spawn.
    static let duration: Double = 0.24
    static let slideDuration: Double = 0.11
    /// How much a merged tile grows at the top of its pop.
    static let popScale: Double = 0.16

    var body: some View {
        let size = GameLayout.boardSize(.twenty48)
        Canvas { ctx, _ in draw(in: ctx, size: size) }
            .frame(width: size.width, height: size.height)
    }

    static func tileColor(_ value: Int) -> Color {
        guard value > 0 else { return Color.primary.opacity(0.06) }
        let step = Double(value.trailingZeroBitCount)   // 2 → 1, 2048 → 11
        let hue: Double = max(0, 0.13 - step * 0.012)
        let brightness: Double = min(1, 0.55 + step * 0.04)
        return Color(hue: hue, saturation: 0.75, brightness: brightness)
    }

    /// Ease in and out (smoothstep).
    static func ease(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return c * c * (3 - 2 * c)
    }

    private static func cellOrigin(_ x: Double, _ y: Double) -> CGPoint {
        let t: Double = GameLayout.tile
        let g: Double = GameLayout.tileGap
        return CGPoint(x: g + x * (t + g), y: g + y * (t + g))
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(GameColors.board))
        for y in 0..<Game2048.size {
            for x in 0..<Game2048.size {
                drawTile(in: ctx, value: 0, x: Double(x), y: Double(y), scale: 1)
            }
        }
        let slideEnd: Double = Self.slideDuration / Self.duration
        guard let move = game.lastMove, progress < 1 else {
            drawGrid(in: ctx, move: nil, settle: 1)
            return
        }
        if progress < slideEnd {
            let t = Self.ease(progress / slideEnd)
            for s in move.slides {
                let x: Double = Double(s.from.x) + Double(s.to.x - s.from.x) * t
                let y: Double = Double(s.from.y) + Double(s.to.y - s.from.y) * t
                drawTile(in: ctx, value: s.value, x: x, y: y, scale: 1)
            }
        } else {
            drawGrid(in: ctx, move: move, settle: (progress - slideEnd) / (1 - slideEnd))
        }
    }

    /// The final grid; `settle` (0…1) runs the merge pops and the spawn's scale-in.
    private func drawGrid(in ctx: GraphicsContext, move: Game2048.Move?, settle: Double) {
        for (y, row) in game.grid.enumerated() {
            for (x, v) in row.enumerated() where v > 0 {
                let p = Point(x: x, y: y)
                var scale: Double = 1
                if let move, settle < 1 {
                    if move.spawned == p {
                        scale = Self.ease(settle)
                    } else if move.merged.contains(p) {
                        scale = 1 + Self.popScale * sin(Double.pi * settle)
                    }
                }
                drawTile(in: ctx, value: v, x: Double(x), y: Double(y), scale: scale)
            }
        }
    }

    private func drawTile(in ctx: GraphicsContext, value v: Int, x: Double, y: Double, scale: Double) {
        guard scale > 0.01 else { return }
        let t: Double = GameLayout.tile
        let o = Self.cellOrigin(x, y)
        let side: Double = t * scale
        let inset: Double = (t - side) / 2
        let r = CGRect(x: o.x + inset, y: o.y + inset, width: side, height: side)
        ctx.fill(Path(roundedRect: r, cornerRadius: 6 * scale), with: .color(Self.tileColor(v)))
        guard v > 0 else { return }
        let sheen = Gradient(colors: [.white.opacity(0.12), .white.opacity(0)])
        let shape = Path(roundedRect: r, cornerRadius: 6 * scale)
        ctx.fill(shape, with: .linearGradient(sheen, startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.midY)))
        let base: Double = v < 100 ? 24 : (v < 1000 ? 20 : 16)
        let label = Text(verbatim: "\(v)").font(.system(size: base * scale, weight: .bold)).foregroundColor(.white)   // on the colored tile, every theme
        ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY))
    }
}
