import PlatyNotchKit
import SwiftUI

/// Platy, the platypus mascot, drawn in code (`PlatyArt`, the master is
/// design/platy/platy.svg) in `mood`, `size` points square.
///
/// Animates on a `TimelineView` only while the panel is really shown (`panelTicking`),
/// Reduce Motion is off and the mood moves at all: idle and focused are one still frame,
/// sleepy redraws once a second, the rest at `PlatyMood.frameInterval`. Otherwise a
/// still frame (`PlatyPose.rest`) that keeps the mood's cue.
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
        Group {
            if let interval = Self.frameInterval(mood: mood, ticking: ticking, reduceMotion: reduceMotion) {
                TimelineView(.animation(minimumInterval: interval)) { ctx in
                    PlatyCanvas(pose: .at(mood, time: ctx.date.timeIntervalSinceReferenceDate), size: size)
                }
            } else {
                PlatyCanvas(pose: .rest(mood), size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(mood.accessibilityLabel)
    }

    /// The redraw interval, nil for a still frame.
    static func frameInterval(mood: PlatyMood, ticking: Bool, reduceMotion: Bool) -> TimeInterval? {
        guard ticking, !reduceMotion else { return nil }
        return mood.frameInterval
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
