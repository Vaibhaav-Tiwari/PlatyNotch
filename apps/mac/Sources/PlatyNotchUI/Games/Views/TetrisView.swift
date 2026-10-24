import PlatyNotchKit
import SwiftUI

/// The Tetris well (10 × 20 cells of `GameLayout.tetrisCell`) with the next piece, score
/// and lines beside it.
struct TetrisView: View {
    let tetris: Tetris

    static let colors: [Color] = [
        Color(nsColor: .systemTeal), Color(nsColor: .systemYellow), Color(nsColor: .systemPurple),
        Color(nsColor: .systemGreen), Color(nsColor: .systemRed), Color(nsColor: .systemBlue),
        Color(nsColor: .systemOrange),
    ]

    static func color(_ value: Int) -> Color {
        let i = max(0, min(value - 1, colors.count - 1))
        return colors[i]
    }

    var body: some View {
        let size = GameLayout.boardSize(.tetris)
        let c: CGFloat = GameLayout.tetrisCell
        let well = CGSize(width: c * CGFloat(tetris.width), height: c * CGFloat(tetris.height))
        HStack(alignment: .top, spacing: GameLayout.tetrisGap) {
            Canvas { ctx, _ in drawWell(in: ctx, size: well) }
                .frame(width: well.width, height: well.height)
            side
                .frame(width: GameLayout.tetrisSide, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityLabel("Tetris, score \(tetris.score), \(tetris.linesCleared) lines")
    }

    private var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Canvas { ctx, _ in drawNext(in: ctx) }
                .frame(width: 48, height: 30)
            Text("Lines").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(verbatim: "\(tetris.linesCleared)").font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
    }

    private func drawWell(in ctx: GraphicsContext, size: CGSize) {
        let c: CGFloat = GameLayout.tetrisCell
        ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4), with: .color(GameColors.board))
        for (y, row) in tetris.board.enumerated() {
            for (x, v) in row.enumerated() where v != 0 {
                fill(ctx, x: x, y: y, cell: c, color: Self.color(v))
            }
        }
        guard !tetris.isOver else { return }
        let color = Self.color(tetris.current.kind.cellValue)
        for p in tetris.current.cells where p.y >= 0 {
            fill(ctx, x: p.x, y: p.y, cell: c, color: color)
        }
    }

    private func drawNext(in ctx: GraphicsContext) {
        guard let next = tetris.queue.first else { return }
        let c: CGFloat = 10
        let color = Self.color(next.cellValue)
        for p in next.cells(rotation: 0) {
            fill(ctx, x: p.x, y: p.y, cell: c, color: color)
        }
    }

    private func fill(_ ctx: GraphicsContext, x: Int, y: Int, cell c: CGFloat, color: Color) {
        let r = CGRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: c, height: c).insetBy(dx: 0.75, dy: 0.75)
        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
    }
}
