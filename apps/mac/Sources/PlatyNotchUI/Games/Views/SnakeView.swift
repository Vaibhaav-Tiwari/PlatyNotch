import PlatyNotchKit
import SwiftUI

/// Colors shared by the boards.
enum GameColors {
    static let board = Color.white.opacity(0.05)
    static let grid = Color.white.opacity(0.03)
    static let accent = Color(nsColor: .systemGreen)
    static let food = Color(nsColor: .systemRed)
}

/// The Snake board: a 24 × 8 grid of `GameLayout.snakeCell` points.
struct SnakeView: View {
    let snake: Snake
    /// 0…1: the food's gentle pulse (always 0 with Reduce Motion).
    let pulse: Double

    var body: some View {
        let size = GameLayout.boardSize(.snake)
        Canvas { ctx, _ in draw(in: ctx, size: size) }
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("Snake, score \(snake.score)")
    }

    private func cell(_ p: PlatyNotchKit.Point) -> CGRect {
        let c: CGFloat = GameLayout.snakeCell
        return CGRect(x: CGFloat(p.x) * c, y: CGFloat(p.y) * c, width: c, height: c)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        ctx.fill(Path(roundedRect: bounds, cornerRadius: 8), with: .color(GameColors.board))
        let shrink: CGFloat = 4 - CGFloat(pulse) * 1.5
        let food = cell(snake.food).insetBy(dx: shrink, dy: shrink)
        ctx.fill(Path(ellipseIn: food), with: .color(GameColors.food))
        for (i, p) in snake.body.enumerated() {
            let r = cell(p).insetBy(dx: 1.5, dy: 1.5)
            let alpha: Double = i == 0 ? 1 : 0.75
            ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(GameColors.accent.opacity(alpha)))
        }
    }
}
