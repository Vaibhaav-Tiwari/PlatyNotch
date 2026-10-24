import PlatyNotchKit
import SwiftUI

/// The 2048 grid: 4 × 4 tiles of `GameLayout.tile` points. Drawn only when a move changes
/// it (no frame loop).
struct Game2048View: View {
    let game: Game2048

    var body: some View {
        let size = GameLayout.boardSize(.twenty48)
        Canvas { ctx, _ in draw(in: ctx, size: size) }
            .frame(width: size.width, height: size.height)
            .accessibilityLabel("2048, score \(game.score)")
    }

    static func tileColor(_ value: Int) -> Color {
        guard value > 0 else { return Color.white.opacity(0.06) }
        let step = Double(value.trailingZeroBitCount)   // 2 → 1, 2048 → 11
        let hue: Double = max(0, 0.13 - step * 0.012)
        let brightness: Double = min(1, 0.55 + step * 0.04)
        return Color(hue: hue, saturation: 0.75, brightness: brightness)
    }

    private func draw(in ctx: GraphicsContext, size: CGSize) {
        let t: CGFloat = GameLayout.tile
        let g: CGFloat = GameLayout.tileGap
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(GameColors.board))
        for (y, row) in game.grid.enumerated() {
            for (x, v) in row.enumerated() {
                let ox: CGFloat = g + CGFloat(x) * (t + g)
                let oy: CGFloat = g + CGFloat(y) * (t + g)
                let r = CGRect(x: ox, y: oy, width: t, height: t)
                ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(Self.tileColor(v)))
                guard v > 0 else { continue }
                let fontSize: CGFloat = v < 1000 ? 20 : 15
                let label = Text(verbatim: "\(v)").font(.system(size: fontSize, weight: .bold)).foregroundColor(.white)
                ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY))
            }
        }
    }
}
