import SwiftUI

/// Three bars bouncing while music plays (12 fps, only while on screen).
/// The one music glyph: the pill and the music widget both use it.
/// Still (fixed heights) with Reduce Motion, and while the panel is hidden or suppressed
/// over full screen (`panelTicking`), so the timeline does no work then.
struct MusicBars: View {
    var color: Color = Theme.color(.active)
    @Environment(\.panelTicking) private var ticking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Self.animates(ticking: ticking, reduceMotion: reduceMotion) {
            TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
                bars(Self.heights(at: ctx.date.timeIntervalSinceReferenceDate))
            }
        } else {
            bars(Self.heights(at: nil))
        }
    }

    private func bars(_ heights: [CGFloat]) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<heights.count, id: \.self) { i in
                Capsule().fill(color).frame(width: 2.5, height: heights[i])
            }
        }
        .frame(height: 10, alignment: .bottom)
        .accessibilityHidden(true)
    }

    static func animates(ticking: Bool, reduceMotion: Bool) -> Bool { ticking && !reduceMotion }

    /// Bar heights at time `t`; `nil` is the still pose.
    static func heights(at t: TimeInterval?) -> [CGFloat] {
        guard let t else { return [6, 9, 5] }
        return (0..<3).map { i in
            let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
            return 4 + 6 * (phase + 1) / 2
        }
    }
}
