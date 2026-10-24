import AppKit
import PlatyNotchKit
import SwiftUI

/// The app icon: the macOS (Big Sur and later) grid, an 824 × 824 rounded square in a
/// 1024 canvas with a soft shadow, a deep blue to night-blue gradient, a notch at the
/// top (the product) and Platy in the middle. Drawn at any size; Platy simplifies below
/// 28 pt like everywhere else.
enum PlatyAppIcon {
    static let canvas: CGFloat = 1024
    static let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    static let plateRadius: CGFloat = 185
    static let notch = CGRect(x: 352, y: 100, width: 320, height: 78)
    /// Platy's square in the 1024 canvas.
    static let platy = CGRect(x: 197, y: 268, width: 630, height: 630)
    /// At 64 px and below Platy fills more of the plate (Dock lists, Finder, Spotlight).
    static let smallPlaty = CGRect(x: 132, y: 196, width: 760, height: 760)

    static func platyRect(pixels: CGFloat) -> CGRect { pixels <= 64 ? smallPlaty : platy }

    static let top = Color(platyHex: 0x1F4E78)
    static let bottom = Color(platyHex: 0x0A1630)
    static let glow = Color(platyHex: 0x3A7FA8)
    static let notchColor = Color(platyHex: 0x05080C)

    static func draw(in ctx: GraphicsContext, size: CGFloat) {
        var g = ctx
        let s: CGFloat = size / canvas
        g.scaleBy(x: s, y: s)
        let plateShape = Path(roundedRect: plate, cornerRadius: plateRadius, style: .continuous)
        drawShadow(g, plate: plateShape)
        var inside = g
        inside.clip(to: plateShape)
        drawBackground(inside)
        drawNotch(inside)
        drawPlaty(inside, pixels: size)
        drawRim(g, plate: plateShape)
    }

    private static func drawShadow(_ g: GraphicsContext, plate: Path) {
        var shadow = g
        shadow.addFilter(.shadow(color: .black.opacity(0.35), radius: 14, x: 0, y: 10))
        shadow.fill(plate, with: .color(bottom))
    }

    private static func drawBackground(_ g: GraphicsContext) {
        let gradient = Gradient(colors: [top, bottom])
        g.fill(Path(plate), with: .linearGradient(gradient, startPoint: CGPoint(x: 512, y: 100),
                                                  endPoint: CGPoint(x: 512, y: 924)))
        let glowGradient = Gradient(colors: [glow.opacity(0.45), glow.opacity(0)])
        g.fill(Path(plate), with: .radialGradient(glowGradient, center: CGPoint(x: 512, y: 600),
                                                  startRadius: 0, endRadius: 400))
    }

    private static func drawNotch(_ g: GraphicsContext) {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 34, bottomTrailingRadius: 34, style: .continuous)
        g.fill(shape.path(in: notch), with: .color(notchColor))
    }

    private static func drawPlaty(_ g: GraphicsContext, pixels: CGFloat) {
        var p = g
        let rect = platyRect(pixels: pixels)
        p.translateBy(x: rect.minX, y: rect.minY)
        // Detail by Platy's size in the final image, not in the 1024 canvas.
        let shown: CGFloat = rect.width * pixels / canvas
        PlatyArt.draw(in: p, size: rect.width, pose: .rest(.idle), detail: PlatyDetail(points: shown))
    }

    /// A faint light edge so the plate reads on a dark Dock.
    private static func drawRim(_ g: GraphicsContext, plate: Path) {
        g.stroke(plate, with: .color(.white.opacity(0.12)), lineWidth: 3)
    }
}

struct PlatyAppIconView: View {
    let size: CGFloat

    var body: some View {
        Canvas { ctx, _ in PlatyAppIcon.draw(in: ctx, size: size) }
            .frame(width: size, height: size)
    }
}

/// The menu bar icon: Platy's silhouette as a monochrome template image (macOS tints it
/// for light and dark menu bars), the eyes cut out and the bill set off by a gap.
/// An optional dot (bottom right) while capture runs.
enum PlatyMenuIcon {
    static let size = NSSize(width: 18, height: 18)
    /// The part of Platy's 100 box the icon shows (a little of the tail tip is cropped).
    static let crop = CGRect(x: 10, y: 12, width: 86, height: 86)

    static func image(dot: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: true) { rect in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            draw(in: cg, rect: rect, dot: dot)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = dot ? "PlatyNotch, capturing" : "PlatyNotch"
        return image
    }

    /// Draws in black on clear into a y-down context.
    static func draw(in cg: CGContext, rect: CGRect, dot: Bool) {
        cg.saveGState()
        let scale: CGFloat = rect.width / crop.width
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -crop.minX, y: -crop.minY)
        cg.setFillColor(NSColor.black.cgColor)
        cg.setStrokeColor(NSColor.black.cgColor)
        fill(cg, PlatyShapes.tail(wag: 0))
        fill(cg, PlatyShapes.silhouette())
        fill(cg, Path(ellipseIn: PlatyShapes.leftFoot))
        fill(cg, Path(ellipseIn: PlatyShapes.rightFoot))
        cutOuts(cg)
        fill(cg, billShape)
        cg.restoreGState()
        if dot { drawDot(cg, rect: rect) }
    }

    /// At 18 pt the bill is drawn wider than the head, so the silhouette reads as a
    /// duck-billed animal even in one color.
    static let bill = CGRect(x: 15, y: 46, width: 70, height: 20)
    static var billShape: Path { Path(roundedRect: bill, cornerRadius: 10, style: .continuous) }

    private static func fill(_ cg: CGContext, _ path: Path) {
        cg.addPath(path.cgPath)
        cg.fillPath()
    }

    /// Eyes, the gap round the bill and the line under the body.
    private static func cutOuts(_ cg: CGContext) {
        cg.saveGState()
        cg.setBlendMode(.clear)
        let r: CGFloat = 6.4
        for c in [PlatyShapes.leftEye, PlatyShapes.rightEye] {
            cg.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        }
        cg.fillPath()
        cg.setLineWidth(8)
        cg.addPath(billShape.cgPath)
        cg.strokePath()
        cg.setLineWidth(3)
        cg.addPath(Path(ellipseIn: PlatyShapes.leftFoot).cgPath)
        cg.addPath(Path(ellipseIn: PlatyShapes.rightFoot).cgPath)
        cg.strokePath()
        cg.restoreGState()
        // The feet again, inside their gap.
        fill(cg, Path(ellipseIn: PlatyShapes.leftFoot.insetBy(dx: 1.5, dy: 1.5)))
        fill(cg, Path(ellipseIn: PlatyShapes.rightFoot.insetBy(dx: 1.5, dy: 1.5)))
    }

    private static func drawDot(_ cg: CGContext, rect: CGRect) {
        let d: CGFloat = 6
        let dot = CGRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
        cg.saveGState()
        cg.setBlendMode(.clear)
        cg.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
        cg.restoreGState()
        cg.setFillColor(NSColor.black.cgColor)
        cg.fillEllipse(in: dot)
    }
}
