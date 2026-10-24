import PlatyNotchKit
import SwiftUI

/// The Tetris well (10 × 20 cells of `GameLayout.tetrisCell`, a 130 × 260 portrait well
/// using nearly the board area's full height) between the stats (left) and the next three
/// pieces (right). The well has faint grid lines, a ghost piece outlining where the piece
/// will land, and a soft lane under the piece down to the ghost, so the landing column
/// and row are plain even near the bottom.
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
            stats
                .frame(width: GameLayout.tetrisSide, alignment: .topTrailing)
            Canvas { ctx, _ in drawWell(in: ctx, size: well) }
                .frame(width: well.width, height: well.height)
            next
                .frame(width: GameLayout.tetrisSide, alignment: .topLeading)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .accessibilityLabel("Tetris, score \(tetris.score), \(tetris.linesCleared) lines, level \(tetris.level)")
    }

    private var stats: some View {
        VStack(alignment: .trailing, spacing: 3) {
            stat("Score", tetris.score)
            stat("Lines", tetris.linesCleared)
            stat("Level", tetris.level)
        }
        .padding(.top, 4)
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(verbatim: "\(value)").font(.system(size: 15, weight: .medium)).monospacedDigit()
        }
        .padding(.bottom, 6)
    }

    private var next: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Next").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Canvas { ctx, _ in drawNext(in: ctx) }
                .frame(width: GameLayout.tetrisSide, height: 150)
        }
        .padding(.top, 4)
    }

    private func drawWell(in ctx: GraphicsContext, size: CGSize) {
        let c: CGFloat = GameLayout.tetrisCell
        let bounds = CGRect(origin: .zero, size: size)
        ctx.fill(Path(roundedRect: bounds, cornerRadius: 4), with: .color(GameColors.well))
        drawGrid(in: ctx, size: size, cell: c)
        for (y, row) in tetris.board.enumerated() {
            for (x, v) in row.enumerated() where v != 0 {
                block(ctx, x: x, y: y, cell: c, color: Self.color(v))
            }
        }
        if !tetris.isOver {
            let color = Self.color(tetris.current.kind.cellValue)
            let ghost = tetris.ghost
            if ghost != tetris.current {
                drawLanes(in: ctx, ghost: ghost, cell: c, color: color)
                for p in ghost.cells where p.y >= 0 { outline(ctx, x: p.x, y: p.y, cell: c, color: color) }
            }
            for p in tetris.current.cells where p.y >= 0 {
                block(ctx, x: p.x, y: p.y, cell: c, color: color)
            }
        }
        ctx.stroke(Path(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4),
                   with: .color(GameColors.wellEdge), lineWidth: 1)
    }

    /// Faint lines between the cells.
    private func drawGrid(in ctx: GraphicsContext, size: CGSize, cell c: CGFloat) {
        var lines = Path()
        for x in 1..<tetris.width {
            let px: CGFloat = CGFloat(x) * c
            lines.move(to: CGPoint(x: px, y: 0))
            lines.addLine(to: CGPoint(x: px, y: size.height))
        }
        for y in 1..<tetris.height {
            let py: CGFloat = CGFloat(y) * c
            lines.move(to: CGPoint(x: 0, y: py))
            lines.addLine(to: CGPoint(x: size.width, y: py))
        }
        ctx.stroke(lines, with: .color(GameColors.gridLine), lineWidth: 0.5)
    }

    /// A soft column tint from under each of the piece's columns down to the ghost.
    private func drawLanes(in ctx: GraphicsContext, ghost: TetrisPiece, cell c: CGFloat, color: Color) {
        var lowest: [Int: Int] = [:]
        for p in tetris.current.cells { lowest[p.x] = max(lowest[p.x] ?? Int.min, p.y) }
        var landing: [Int: Int] = [:]
        for p in ghost.cells { landing[p.x] = max(landing[p.x] ?? Int.min, p.y) }
        for (x, from) in lowest {
            guard let to = landing[x], to > from else { continue }
            let top: CGFloat = CGFloat(max(from + 1, 0)) * c
            let bottom: CGFloat = CGFloat(to + 1) * c
            let lane = CGRect(x: CGFloat(x) * c, y: top, width: c, height: bottom - top)
            ctx.fill(Path(lane), with: .color(color.opacity(0.09)))
        }
    }

    private func drawNext(in ctx: GraphicsContext) {
        var y: CGFloat = 0
        for (i, kind) in tetris.queue.prefix(3).enumerated() {
            let c: CGFloat = i == 0 ? 13 : 10
            var piece = ctx
            piece.translateBy(x: 0, y: y)
            let color = Self.color(kind.cellValue)
            for p in kind.cells(rotation: 0) {
                block(piece, x: p.x, y: p.y, cell: c, color: color)
            }
            y += c * 2 + (i == 0 ? 18 : 14)
        }
    }

    /// A locked or falling block: the colour, a light top-left bevel and a darker bottom.
    private func block(_ ctx: GraphicsContext, x: Int, y: Int, cell c: CGFloat, color: Color) {
        let r = CGRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: c, height: c).insetBy(dx: 0.75, dy: 0.75)
        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color))
        let top = CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height * 0.3)
        ctx.fill(Path(roundedRect: top, cornerRadius: 2), with: .color(.white.opacity(0.22)))
        let bottom = CGRect(x: r.minX, y: r.maxY - r.height * 0.22, width: r.width, height: r.height * 0.22)
        ctx.fill(Path(roundedRect: bottom, cornerRadius: 2), with: .color(.black.opacity(0.18)))
    }

    /// A ghost cell: a tinted fill and a clear outline.
    private func outline(_ ctx: GraphicsContext, x: Int, y: Int, cell c: CGFloat, color: Color) {
        let r = CGRect(x: CGFloat(x) * c, y: CGFloat(y) * c, width: c, height: c).insetBy(dx: 1.25, dy: 1.25)
        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color.opacity(0.18)))
        ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(color.opacity(0.85)), lineWidth: 1.4)
    }
}
