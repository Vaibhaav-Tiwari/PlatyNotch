import AppKit
import PlatyNotchKit
import SwiftUI

/// Platy, the platypus mascot, drawn in code (`PlatyArt`, the master is
/// design/platy/platy.svg) in `mood`, `size` points square.
///
/// The loop (`PlatyPoseValues.loop`: at most 12 fps, waiting 6 fps, sleepy 1 fps) is drawn
/// once into images and played by Core
/// Animation as a discrete keyframe animation of a layer's contents: the render server
/// steps the frames, the app does no work per frame. It plays only while the panel is
/// really shown (`panelTicking`), Reduce Motion is off and the mood moves; otherwise the
/// still frame (`PlatyPose.rest`), which keeps the mood's cue. Idle and focused are still.
/// Waiting and done (`PlatyMood.playsOnce`) play their loop once, then hold the still
/// frame; entering the mood again plays it again.
struct PlatyView: View {
    let mood: PlatyMood
    let size: CGFloat
    @Environment(\.panelTicking) private var ticking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(mood: PlatyMood, size: CGFloat) {
        self.mood = mood
        self.size = size
    }

    var body: some View {
        let animates = Self.frameInterval(mood: mood, ticking: ticking, reduceMotion: reduceMotion) != nil
        PlatyLayerView(mood: mood, size: size, animates: animates)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(mood.accessibilityLabel)
    }

    /// The loop's frame interval when it plays, nil for a still frame.
    static func frameInterval(mood: PlatyMood, ticking: Bool, reduceMotion: Bool) -> TimeInterval? {
        guard ticking, !reduceMotion else { return nil }
        return mood.frameInterval
    }
}

/// Hosts Platy's layer.
private struct PlatyLayerView: NSViewRepresentable {
    let mood: PlatyMood
    let size: CGFloat
    let animates: Bool

    func makeNSView(context: Context) -> PlatyLayerNSView {
        PlatyLayerNSView()
    }

    func updateNSView(_ view: PlatyLayerNSView, context: Context) {
        view.configure(PlatyLayerNSView.Config(mood: mood, size: size, animates: animates))
    }
}

/// A layer showing Platy's still frame or playing its loop.
final class PlatyLayerNSView: NSView {
    struct Config: Equatable {
        var mood: PlatyMood
        var size: CGFloat
        var animates: Bool
    }

    static let animationKey = "platy.loop"
    private let platy = CALayer()
    private var config: Config?
    private var appliedScale: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        platy.contentsGravity = .resizeAspect
        platy.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(platy)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        platy.frame = bounds
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply()
    }

    func configure(_ new: Config) {
        guard new != config else { return }
        config = new
        appliedScale = 0
        apply()
    }

    /// Whether the loop is playing (tests).
    var isPlaying: Bool { platy.animation(forKey: Self.animationKey) != nil }

    /// The loop's repeat count (tests): 1 for a `playsOnce` mood, else infinity.
    var loopRepeatCount: Float? { platy.animation(forKey: Self.animationKey)?.repeatCount }

    /// After a `playsOnce` loop the layer shows its still frame (tests).
    var holdsStillAfterLoop: Bool {
        guard let config, let a = platy.animation(forKey: Self.animationKey),
              let still = PlatyFrames.still(config.mood, size: config.size, scale: appliedScale) else { return false }
        return a.isRemovedOnCompletion && (platy.contents as AnyObject?) === still
    }

    private func apply() {
        guard let config else { return }
        let scale: CGFloat = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard scale != appliedScale else { return }
        appliedScale = scale
        platy.contentsScale = scale
        platy.removeAnimation(forKey: Self.animationKey)
        let frames = PlatyFrames.frames(config.mood, size: config.size, scale: scale)
        guard config.animates, frames.images.count > 1 else {
            platy.contents = PlatyFrames.still(config.mood, size: config.size, scale: scale)
            return
        }
        let once: Bool = config.mood.playsOnce
        // A once-only loop leaves the still frame behind when it ends (removed on
        // completion, so nothing runs afterwards); a looping one starts on its first frame.
        platy.contents = once ? PlatyFrames.still(config.mood, size: config.size, scale: scale) : frames.images.first
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.images
        animation.keyTimes = frames.keyTimes
        animation.calculationMode = .discrete
        animation.duration = config.mood.period
        animation.repeatCount = once ? 1 : .infinity
        animation.isRemovedOnCompletion = once
        platy.add(animation, forKey: Self.animationKey)
    }
}

/// Platy's loops drawn into images once per mood, size and scale (a few KB each).
@MainActor
enum PlatyFrames {
    struct Loop {
        let images: [CGImage]
        /// One more than `images` (0 … 1), as discrete keyframes want.
        let keyTimes: [NSNumber]
    }

    private struct Key: Hashable {
        let mood: PlatyMood
        let size: CGFloat
        let scale: CGFloat
    }

    private static var loops: [Key: Loop] = [:]
    private static var stills: [Key: CGImage] = [:]

    static func frames(_ mood: PlatyMood, size: CGFloat, scale: CGFloat) -> Loop {
        let key = Key(mood: mood, size: size, scale: scale)
        if let cached = loops[key] { return cached }
        let loop = PlatyPoseValues.loop(mood)
        let images: [CGImage] = loop.compactMap { render(PlatyPose($0.pose), size: size, scale: scale) }
        var times: [NSNumber] = loop.map { NSNumber(value: $0.time / mood.period) }
        times.append(1)
        let built = Loop(images: images, keyTimes: images.count == loop.count ? times : [0, 1])
        loops[key] = built
        return built
    }

    static func still(_ mood: PlatyMood, size: CGFloat, scale: CGFloat) -> CGImage? {
        let key = Key(mood: mood, size: size, scale: scale)
        if let cached = stills[key] { return cached }
        let image = render(.rest(mood), size: size, scale: scale)
        stills[key] = image
        return image
    }

    static func render(_ pose: PlatyPose, size: CGFloat, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: PlatyCanvas(pose: pose, size: size))
        renderer.scale = scale
        return renderer.cgImage
    }
}

/// One frame of Platy.
struct PlatyCanvas: View {
    let pose: PlatyPose
    let size: CGFloat
    var detail: PlatyDetail?

    var body: some View {
        Canvas { ctx, _ in
            PlatyArt.draw(in: ctx, size: size, pose: pose, detail: detail)
        }
        .frame(width: size, height: size)
    }
}
