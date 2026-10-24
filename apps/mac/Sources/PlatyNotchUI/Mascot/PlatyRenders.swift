import AppKit
import PlatyNotchKit
import SwiftUI

/// The hidden `--render-icon <dir>` and `--platy-gallery <dir>` flags (C35): PNGs drawn by
/// the same code as the app, no window, no core. `iconutil -c icns <dir>/AppIcon.iconset`
/// then makes apps/mac/Resources/AppIcon.icns.
@MainActor
enum PlatyRenders {
    struct Failure: Error {
        let message: String
    }

    /// (file name, points, scale) of an .iconset: 10 images, 16 to 1024 px.
    static let iconsetEntries: [(String, CGFloat, CGFloat)] = [16, 32, 128, 256, 512].flatMap { pt -> [(String, CGFloat, CGFloat)] in
        let base = "icon_\(Int(pt))x\(Int(pt))"
        return [(base + ".png", CGFloat(pt), 1), (base + "@2x.png", CGFloat(pt), 2)]
    }

    /// Writes `<dir>/AppIcon.iconset/*.png`; returns how many.
    static func writeIconset(to dir: URL) -> Result<Int, Failure> {
        let set = dir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
            for (name, points, scale) in iconsetEntries {
                let pixels: CGFloat = points * scale
                try write(png(PlatyAppIconView(size: pixels), scale: 1), to: set.appendingPathComponent(name))
            }
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        return .success(iconsetEntries.count)
    }

    /// Writes the art review set: the contact sheet (every mood at 22 and 96 pt on dark
    /// and light, at 1x and 2x), the icon at 1024 / 128 / 32 / 16 px, the menu bar
    /// template on light and dark bars, the pill, and every game (`games/`, `GameRenders`). Returns how many files.
    static func writeGallery(to dir: URL) -> Result<Int, Failure> {
        var count = 0
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for scale in [CGFloat(1), 2] {
                try write(png(PlatyContactSheet(), scale: scale), to: dir.appendingPathComponent("contact-sheet@\(Int(scale))x.png"))
                count += 1
            }
            for px in [1024, 128, 32, 16] {
                let view = PlatyAppIconView(size: CGFloat(px))
                try write(png(view, scale: 1), to: dir.appendingPathComponent("icon-\(px).png"))
                count += 1
            }
            for dark in [false, true] {
                for scale in [1, 2] {
                    let name = "menubar-\(dark ? "dark" : "light")@\(scale)x.png"
                    try write(menuBarPreview(dark: dark, scale: scale), to: dir.appendingPathComponent(name))
                    count += 1
                }
            }
            try write(png(PlatyPillPreview(), scale: 2), to: dir.appendingPathComponent("pill@2x.png"))
            count += 1
            // The live views (layer-backed, as in the pill) in a hosting view: still frames.
            try write(hosted(PlatyLiveStrip()), to: dir.appendingPathComponent("pill-live-views.png"))
            count += 1
            // Pill size on a Retina display (22 pt at 2x), blown up 4x without smoothing.
            try write(zoomed(png(PlatyPillStrip(), scale: 2), by: 4), to: dir.appendingPathComponent("pill-moods-22pt@2x-zoom4.png"))
            count += 1
            // Every game in several states, mid-animation frames included.
            count += try GameRenders.write(to: dir.appendingPathComponent("games", isDirectory: true))
        } catch let f as Failure {
            return .failure(f)
        } catch {
            return .failure(Failure(message: error.localizedDescription))
        }
        return .success(count)
    }

    static func png<V: View>(_ view: V, scale: CGFloat) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A view drawn by an off-screen hosting view (layer-backed views included).
    static func hosted<V: View>(_ view: V) -> Data? {
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard host.bounds.width > 0, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// The PNG scaled up `factor` times with nearest-neighbour sampling (every pixel shows).
    static func zoomed(_ data: Data?, by factor: Int) -> Data? {
        guard let data, let src = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        let w = src.width * factor
        let h = src.height * factor
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }

    static func write(_ data: Data?, to url: URL) throws {
        guard let data else { throw Failure(message: "\(url.lastPathComponent) did not render") }
        do { try data.write(to: url) } catch { throw Failure(message: "cannot write \(url.path)") }
    }

    /// The template icon tinted the way macOS does: black on a light bar, white on a dark one.
    static func menuBarPreview(dark: Bool, scale: Int) -> Data? {
        let width = 64 * scale
        let height = 24 * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ns = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ns.cgContext
        let s = CGFloat(scale)
        // y down, in points.
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: s, y: -s)
        let bar: NSColor = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        let ink: NSColor = dark ? .white : NSColor(white: 0.1, alpha: 1)
        cg.setFillColor(bar.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: 64, height: 24))
        for (i, dot) in [false, true].enumerated() {
            let rect = CGRect(x: 8 + CGFloat(i) * 30, y: 3, width: 18, height: 18)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            PlatyMenuIcon.draw(in: cg, rect: rect, dot: dot)
            cg.setBlendMode(.sourceIn)
            cg.setFillColor(ink.cgColor)
            cg.fill(rect.insetBy(dx: -2, dy: -2))
            cg.endTransparencyLayer()
        }
        ns.flushGraphics()
        return rep.representation(using: .png, properties: [:])
    }
}

/// Every mood at pill size (22 pt) and large (96 pt), on the pill's black and a light surface.
struct PlatyContactSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PlatyMood.allCases, id: \.self) { mood in
                HStack(spacing: 0) {
                    Text(verbatim: mood.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.2))
                        .frame(width: 96, alignment: .leading)
                        .padding(.leading, 12)
                    cell(mood, dark: true)
                    cell(mood, dark: false)
                }
            }
        }
        .padding(.vertical, 8)
        .background(Color(white: 0.85))
    }

    private func cell(_ mood: PlatyMood, dark: Bool) -> some View {
        HStack(spacing: 16) {
            PlatyCanvas(pose: .rest(mood), size: 22)
            PlatyCanvas(pose: .at(mood, time: mood.period * 0.3), size: 22)
            PlatyCanvas(pose: .rest(mood), size: 96)
            PlatyCanvas(pose: .at(mood, time: mood.period * 0.3), size: 96)
        }
        .padding(10)
        .background(dark ? Color.black : Color(platyHex: 0xF4F4F2))
    }
}

/// Every mood at 22 pt (still and mid-loop), on black and on light.
struct PlatyPillStrip: View {
    var body: some View {
        VStack(spacing: 0) {
            row(dark: true)
            row(dark: false)
        }
    }

    private func row(dark: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(PlatyMood.allCases, id: \.self) { mood in
                PlatyCanvas(pose: .rest(mood), size: 22)
                PlatyCanvas(pose: .at(mood, time: mood.period * 0.3), size: 22)
            }
        }
        .padding(6)
        .background(dark ? Color.black : Color(platyHex: 0xF4F4F2))
    }
}

/// Every mood through `PlatyView` (the app's layer-backed view) and the agent dots.
struct PlatyLiveStrip: View {
    var body: some View {
        HStack(spacing: 6) {
            ForEach(PlatyMood.allCases, id: \.self) { PlatyView(mood: $0, size: 22) }
            AgentDot(tone: .active)
            AgentDot(tone: .attention)
        }
        .padding(6)
        .background(Color.black)
        .environment(\.panelTicking, false)
    }
}

/// The resting pill beside a notch: Platy and two agent dots, the notch, a timer ear.
struct PlatyPillPreview: View {
    var body: some View {
        VStack(spacing: 8) {
            ForEach([PlatyMood.idle, .working, .workingToMusic, .waiting, .dancing, .sleepy, .done], id: \.self) { mood in
                HStack(spacing: 0) {
                    HStack(spacing: PlatyEarFit.spacing) {
                        PlatyCanvas(pose: .rest(mood), size: PlatyEarFit.platy)
                        // Plain circles: ImageRenderer draws an NSViewRepresentable (AgentDot's
                        // layer) as a placeholder square (A3).
                        Circle().fill(Color(nsColor: Theme.nsColor(.active))).frame(width: 7, height: 7)
                        Circle().fill(Color(nsColor: Theme.nsColor(.attention))).frame(width: 7, height: 7)
                    }
                    .frame(width: 64)
                    Color.black.frame(width: 180)
                    Text(verbatim: "4:59")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.gray)
                        .frame(width: 64)
                }
                .frame(height: 32)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
            }
        }
        .padding(12)
        .background(Color(white: 0.7))
        .environment(\.colorScheme, .dark)
    }
}
