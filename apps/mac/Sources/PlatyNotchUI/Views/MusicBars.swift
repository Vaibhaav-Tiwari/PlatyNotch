import AppKit
import SwiftUI

/// Bars that move while music plays. The one music glyph: the pill (3 small bars) and the
/// music tile (more, taller bars) both use it.
///
/// Drawn by Core Animation layers (`MusicBarsNSView`), so the app does no SwiftUI work per
/// frame (a 12 fps SwiftUI timeline here cost about 2% CPU while music played):
/// - Synthetic (no visualiser, or no signal yet): each bar is a repeating keyframe
///   animation of its height, played by the render server.
/// - Live (visualiser on and audio arriving, `MusicVisualiser.hasSignal`): the view
///   observes the band levels itself and sets the layer heights with actions off, at most
///   as often as the analyser updates (30 fps); no SwiftUI body runs per update.
/// - Still (fixed heights) with Reduce Motion, and while the panel is hidden or suppressed
///   over full screen (`panelTicking`).
///
/// Each instance tells the visualiser whether it is on screen and animating; the audio tap
/// runs only while at least one is.
struct MusicBars: View {
    var color: Color = Theme.color(.active)
    var count: Int = 3
    var height: CGFloat = 10
    var barWidth: CGFloat = 2.5
    var spacing: CGFloat = 2
    @Environment(\.panelTicking) private var ticking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.musicVisualiser) private var visualiser
    @State private var token = UUID()

    var body: some View {
        let animates = Self.animates(ticking: ticking, reduceMotion: reduceMotion)
        let live: Bool = animates && (visualiser?.enabled ?? false) && (visualiser?.hasSignal ?? false)
        let mode: MusicBarsNSView.Mode = live ? .live : (animates ? .synthetic : .still)
        let width: CGFloat = CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * spacing
        MusicBarsLayer(style: .init(color: NSColor(color), count: count, height: height, barWidth: barWidth,
                                    spacing: spacing),
                       mode: mode, visualiser: live ? visualiser : nil)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .onAppear { visualiser?.setViewer(token, visible: animates) }
            .onDisappear { visualiser?.setViewer(token, visible: false) }
            .onChange(of: animates) { _, now in visualiser?.setViewer(token, visible: now) }
    }

    /// One bar's synthetic loop: the sine `heights(at:)` draws for bar `bar`, sampled
    /// `samples` times over its own period. (seconds per loop, heights, offset of t = 0
    /// into the loop so the bars stay out of step as before).
    static func syntheticLoop(bar: Int, height: CGFloat = 10, samples: Int = 24)
        -> (duration: TimeInterval, heights: [CGFloat]) {
        let speed: Double = 5 + Double(bar) * 1.7
        let period: Double = 2 * Double.pi / speed
        let scale: CGFloat = height / 10
        var out: [CGFloat] = []
        for k in 0...samples {
            let t: Double = period * Double(k) / Double(samples)
            let phase: Double = sin(t * speed + Double(bar))
            let value: Double = 4 + 3 * (phase + 1)
            out.append(CGFloat(value) * scale)
        }
        return (period, out)
    }

    static func animates(ticking: Bool, reduceMotion: Bool) -> Bool { ticking && !reduceMotion }

    /// Synthetic bar heights at time `t`; `nil` is the still pose. Scaled from the pill's
    /// 10 pt bars (4…10 pt) to `height`.
    static func heights(at t: TimeInterval?, count: Int = 3, height: CGFloat = 10) -> [CGFloat] {
        let scale = height / 10
        guard let t else {
            let still: [CGFloat] = [6, 9, 5]
            return (0..<count).map { still[$0 % still.count] * scale }
        }
        return (0..<count).map { i in
            // Explicit Double, then one CGFloat conversion: mixing the two with literals
            // took 1.5 s to type-check on CI's compiler.
            let speed: Double = 5 + Double(i) * 1.7
            let phase: Double = sin(t * speed + Double(i))
            let bar: Double = 4 + 3 * (phase + 1)
            return CGFloat(bar) * scale
        }
    }

    /// Live heights: a 0…1 level per bar, never below a visible stub.
    static func heights(levels: [Float], height: CGFloat) -> [CGFloat] {
        let floor = height * 0.2
        return levels.map { floor + (height - floor) * CGFloat(min(max($0, 0), 1)) }
    }
}

private struct MusicBarsLayer: NSViewRepresentable {
    let style: MusicBarsNSView.Style
    let mode: MusicBarsNSView.Mode
    let visualiser: MusicVisualiser?

    func makeNSView(context: Context) -> MusicBarsNSView { MusicBarsNSView() }

    func updateNSView(_ view: MusicBarsNSView, context: Context) {
        view.configure(style: style, mode: mode, visualiser: visualiser)
    }
}

/// The bars as layers, growing up from the bottom.
final class MusicBarsNSView: NSView {
    enum Mode: Equatable { case still, synthetic, live }

    struct Style: Equatable {
        var color: NSColor
        var count: Int
        var height: CGFloat
        var barWidth: CGFloat
        var spacing: CGFloat
    }

    static let animationKey = "bars.bounce"
    private var bars: [CALayer] = []
    private var style: Style?
    private(set) var mode: Mode = .still
    private weak var visualiser: MusicVisualiser?
    /// Bumped on every reconfigure, so an old levels observer stops.
    private var generation = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    func configure(style: Style, mode: Mode, visualiser: MusicVisualiser?) {
        guard style != self.style || mode != self.mode || visualiser !== self.visualiser else { return }
        let rebuild = style != self.style
        self.style = style
        self.mode = mode
        self.visualiser = visualiser
        generation += 1
        if rebuild { buildBars(style) }
        for bar in bars { bar.removeAnimation(forKey: Self.animationKey) }
        switch mode {
        case .still:
            setHeights(MusicBars.heights(at: nil, count: style.count, height: style.height))
        case .synthetic:
            startSynthetic(style)
        case .live:
            observeLevels(generation)
        }
    }

    /// Whether the bars are bouncing on their own (tests).
    var isBouncing: Bool { bars.contains { $0.animation(forKey: Self.animationKey) != nil } }
    /// The bars' current model heights (tests).
    var barHeights: [CGFloat] { bars.map(\.bounds.height) }

    private func buildBars(_ style: Style) {
        for bar in bars { bar.removeFromSuperlayer() }
        bars = (0..<style.count).map { i in
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)
            let x: CGFloat = CGFloat(i) * (style.barWidth + style.spacing) + style.barWidth / 2
            bar.position = CGPoint(x: x, y: 0)
            bar.bounds = CGRect(x: 0, y: 0, width: style.barWidth, height: style.height / 2)
            bar.cornerRadius = style.barWidth / 2
            bar.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull()]
            layer?.addSublayer(bar)
            return bar
        }
        applyColor()
    }

    private func applyColor() {
        guard let style else { return }
        var cg: CGColor = style.color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = style.color.cgColor }
        for bar in bars { bar.backgroundColor = cg }
    }

    private func setHeights(_ heights: [CGFloat]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bar, h) in zip(bars, heights) {
            bar.bounds = CGRect(x: 0, y: 0, width: bar.bounds.width, height: h)
        }
        CATransaction.commit()
    }

    private func startSynthetic(_ style: Style) {
        setHeights(MusicBars.heights(at: nil, count: style.count, height: style.height))
        for (i, bar) in bars.enumerated() {
            let loop = MusicBars.syntheticLoop(bar: i, height: style.height)
            let bounce = CAKeyframeAnimation(keyPath: "bounds.size.height")
            bounce.values = loop.heights.map { NSNumber(value: Double($0)) }
            bounce.duration = loop.duration
            bounce.repeatCount = .infinity
            bounce.calculationMode = .linear
            bounce.isRemovedOnCompletion = false
            bar.add(bounce, forKey: Self.animationKey)
        }
    }

    /// Follows the visualiser's levels without any SwiftUI view update: each change sets
    /// the layer heights, then observes again.
    private func observeLevels(_ token: Int) {
        guard token == generation, mode == .live, let visualiser, let style else { return }
        let levels = withObservationTracking {
            visualiser.levels
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeLevels(token) }
        }
        let grouped = MusicVisualiser.group(levels, into: style.count)
        setHeights(MusicBars.heights(levels: grouped, height: style.height))
    }
}
