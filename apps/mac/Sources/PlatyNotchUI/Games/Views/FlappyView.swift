import PlatyNotchKit
import SwiftUI

/// Flappy: the engine's world scaled by `GameLayout.flappyScale`.
struct FlappyView: View {
    let flappy: Flappy
    /// The bird tilts with its speed (off with Reduce Motion).
    let decorate: Bool

    var body: some View {
        let size = GameLayout.boardSize(.flappy)
        Canvas { ctx, _ in draw(in: ctx, size: size) }
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Flappy, score \(flappy.score)")
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let k: CGFloat = GameLayout.flappyScale
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(GameColors.board))
        let pipeColor = GameColors.accent.opacity(0.8)
        let w: CGFloat = CGFloat(Flappy.pipeWidth) * k
        for p in flappy.pipes {
            let x: CGFloat = CGFloat(p.x) * k
            let top: CGFloat = CGFloat(p.gapY - p.gapHeight / 2) * k
            let bottom: CGFloat = CGFloat(p.gapY + p.gapHeight / 2) * k
            let upper = CGRect(x: x, y: 0, width: w, height: max(0, top))
            let lower = CGRect(x: x, y: bottom, width: w, height: max(0, size.height - bottom))
            ctx.fill(Path(roundedRect: upper, cornerRadius: 3), with: .color(pipeColor))
            ctx.fill(Path(roundedRect: lower, cornerRadius: 3), with: .color(pipeColor))
        }
        drawBird(in: ctx, scale: k)
    }

    private func drawBird(in ctx: GraphicsContext, scale k: CGFloat) {
        let r: CGFloat = CGFloat(Flappy.birdRadius) * k
        let center = CGPoint(x: CGFloat(Flappy.birdX) * k, y: CGFloat(flappy.birdY) * k)
        var bird = ctx
        bird.translateBy(x: center.x, y: center.y)
        if decorate {
            let tilt: Double = max(-0.5, min(0.9, flappy.velocity / 400))
            bird.rotate(by: .radians(tilt))
        }
        let body = CGRect(x: -r, y: -r, width: r * 2, height: r * 2)
        bird.fill(Path(ellipseIn: body), with: .color(Color(nsColor: .systemYellow)))
        let beak = CGRect(x: r * 0.6, y: -r * 0.25, width: r * 0.7, height: r * 0.5)
        bird.fill(Path(roundedRect: beak, cornerRadius: 2), with: .color(Color(nsColor: .systemOrange)))
    }
}
