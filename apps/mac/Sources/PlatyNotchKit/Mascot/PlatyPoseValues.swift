import Foundation

/// Platy's pose as plain numbers (C34): the UI's `PlatyPose` adds the SwiftUI tint and
/// `PlatyView` draws it. Distances are fractions of Platy's height; angles in degrees.
public struct PlatyPoseValues: Equatable, Sendable {
    /// A tint over the body (the UI maps it to a color).
    public enum Tint: Equatable, Sendable { case none, amber }

    /// 1 open, 0 closed (a happy/sleepy curve).
    public var eyesOpen: Double = 1
    /// Bill tilt in degrees (thinking, talking).
    public var billAngle: Double = 0
    /// Tail swing, -1...1 (1 = raised for a tap).
    public var tailWag: Double = 0
    /// How far Platy is lifted, fraction of its height (0 = standing).
    public var bounce: Double = 0
    /// Breathing, fraction of body height added (sleepy).
    public var breath: Double = 0
    /// Front paws paddling, -1...1 (left up at 1, right up at -1).
    public var paddle: Double = 0
    /// The whole figure leans, degrees (dancing sway, thinking).
    public var lean: Double = 0
    /// Sparkles beside Platy, 0 none ... 1 the big celebration burst.
    public var sparkle: Double = 0
    public var headphones = false
    /// The small green check badge (done).
    public var check = false
    /// The little "z"s (sleepy).
    public var zzz = false
    /// Both paws up (celebrating).
    public var cheer = false
    /// A water line at Platy's feet (working: paddling along). Drawn at every size, so
    /// working reads at 22 pt and in still frames.
    public var water = false
    /// The amber flag Platy holds up (waiting: needs you).
    public var flag = false
    /// The flag's swing in degrees about the bottom of its pole (0 = upright).
    public var flagAngle: Double = 0
    public var tint: Tint = .none

    public init() {}

    /// The pose at `time` seconds; repeats every `mood.period`, except a `playsOnce` mood,
    /// which is `rest` from `period` on (and before 0). Values are rounded to a millionth so
    /// `at(t)` and `at(t + period)` compare equal.
    public static func at(_ mood: PlatyMood, time: TimeInterval) -> PlatyPoseValues {
        guard mood.animates else { return rest(mood) }
        if mood.playsOnce, time < 0 || time >= mood.period { return rest(mood) }
        let period: Double = mood.period
        var phase: Double = time.truncatingRemainder(dividingBy: period) / period
        if phase < 0 { phase += 1 }
        return animated(mood, phase: phase).rounded()
    }

    /// One loop of `mood` as keyframes: (seconds from the loop's start, pose), on the
    /// `PlatyMood.nextFrame` ticks, a frame only where the pose changes (waiting holds one
    /// frame through its still half). A still mood is one frame.
    public static func loop(_ mood: PlatyMood) -> [(time: TimeInterval, pose: PlatyPoseValues)] {
        guard mood.animates, mood.frameInterval != nil else { return [(0, rest(mood))] }
        var out: [(time: TimeInterval, pose: PlatyPoseValues)] = []
        var t: TimeInterval = 0
        while t < mood.period - 1e-9 {
            let pose = at(mood, time: t)
            if out.last?.pose != pose { out.append((t, pose)) }
            t = mood.nextFrame(after: t)
        }
        return out
    }

    /// The still frame: Reduce Motion, a paused panel, the gallery and the icon. Every
    /// mood's cue stays (amber, headphones, closed eyes, check, sparkle).
    public static func rest(_ mood: PlatyMood) -> PlatyPoseValues {
        var p = PlatyPoseValues()
        switch mood {
        case .idle: break
        case .working: p.paddle = 0.6; p.water = true
        case .workingToMusic: p.paddle = 0.6; p.water = true; p.headphones = true
        case .thinking: p.lean = -6; p.billAngle = -4; p.eyesOpen = 0.85
        case .waiting: p.tint = .amber; p.tailWag = 0.6; p.flag = true
        case .done: p.check = true; p.sparkle = 0.5
        case .dancing: p.headphones = true; p.lean = 6; p.eyesOpen = 0
        case .focused: p.eyesOpen = 0.45
        case .sleepy: p.eyesOpen = 0; p.zzz = true
        case .celebrating: p.sparkle = 1; p.cheer = true; p.bounce = 0.06
        }
        return p
    }

    // MARK: - Private

    private static func wave(_ phase: Double, _ cycles: Double = 1) -> Double {
        sin(2 * Double.pi * phase * cycles)
    }

    private static func animated(_ mood: PlatyMood, phase: Double) -> PlatyPoseValues {
        var p = rest(mood)
        switch mood {
        case .working, .workingToMusic:
            // Paws paddle once a loop; the body bobs on every stroke.
            p.paddle = wave(phase)
            p.bounce = 0.03 * abs(wave(phase))
            p.tailWag = 0.3 * wave(phase, 2)
        case .thinking:
            p.lean = -6 + 3 * wave(phase)
            p.billAngle = -4 * wave(phase)
        case .waiting:
            // One 2 s wave: the flag swings twice, dying away to upright, and the tail
            // taps with it; then the still frame (`playsOnce`).
            let fade: Double = 1 - phase
            // Toward Platy's head only, so the pennant stays inside Platy's square.
            p.flagAngle = -16 * abs(wave(phase, 2)) * fade
            p.tailWag = 0.6 + 0.6 * wave(phase, 2) * fade
            p.bounce = 0.02 * abs(wave(phase, 2)) * fade
        case .done:
            p.sparkle = 0.5 + 0.15 * wave(phase)
            p.bounce = 0.015 * abs(wave(phase))
        case .dancing:
            // Bounce on each beat, sway over two.
            p.bounce = 0.05 * abs(wave(phase))
            p.lean = 8 * wave(phase)
            p.tailWag = 0.5 * wave(phase)
            p.paddle = 0.5 * wave(phase, 2)
        case .sleepy:
            p.breath = 0.03 * (0.5 + 0.5 * wave(phase))
        case .celebrating:
            // One jump per loop.
            p.bounce = 0.14 * max(0, wave(phase / 2))
            p.sparkle = 0.85 + 0.15 * wave(phase, 2)
            p.lean = 4 * wave(phase)
        case .idle, .focused:
            break
        }
        return p
    }

    private static func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }

    private func rounded() -> PlatyPoseValues {
        var p = self
        p.eyesOpen = Self.round6(eyesOpen)
        p.billAngle = Self.round6(billAngle)
        p.tailWag = Self.round6(tailWag)
        p.bounce = Self.round6(bounce)
        p.breath = Self.round6(breath)
        p.paddle = Self.round6(paddle)
        p.lean = Self.round6(lean)
        p.sparkle = Self.round6(sparkle)
        p.flagAngle = Self.round6(flagAngle)
        return p
    }
}
