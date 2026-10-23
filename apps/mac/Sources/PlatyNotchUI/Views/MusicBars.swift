import SwiftUI

/// Bars that move while music plays. The one music glyph: the pill (3 small bars) and the
/// music tile (more, taller bars) both use it.
///
/// With the live visualiser on and audio arriving (`MusicVisualiser.hasSignal`) the bars
/// follow the sound, redrawn only when the levels change (at most 30 fps). Otherwise they
/// bounce on a synthetic 12 fps timeline, as before the visualiser existed, so turning the
/// visualiser off adds no per-frame work. Still (fixed heights) with Reduce Motion, and
/// while the panel is hidden or suppressed over full screen (`panelTicking`).
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
        Group {
            if animates, let visualiser, visualiser.enabled, visualiser.hasSignal {
                bars(Self.heights(levels: MusicVisualiser.group(visualiser.levels, into: count), height: height))
            } else if animates {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
                    bars(Self.heights(at: ctx.date.timeIntervalSinceReferenceDate, count: count, height: height))
                }
            } else {
                bars(Self.heights(at: nil, count: count, height: height))
            }
        }
        .onAppear { visualiser?.setViewer(token, visible: animates) }
        .onDisappear { visualiser?.setViewer(token, visible: false) }
        .onChange(of: animates) { _, now in visualiser?.setViewer(token, visible: now) }
    }

    private func bars(_ heights: [CGFloat]) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(0..<heights.count, id: \.self) { i in
                Capsule().fill(color).frame(width: barWidth, height: heights[i])
            }
        }
        .frame(height: height, alignment: .bottom)
        .accessibilityHidden(true)
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
            let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
            return (4 + 6 * (phase + 1) / 2) * scale
        }
    }

    /// Live heights: a 0…1 level per bar, never below a visible stub.
    static func heights(levels: [Float], height: CGFloat) -> [CGFloat] {
        let floor = height * 0.2
        return levels.map { floor + (height - floor) * CGFloat(min(max($0, 0), 1)) }
    }
}
