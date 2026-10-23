import SwiftUI

/// Three bars bouncing while music plays (12 fps, only while on screen).
/// The one music glyph: the pill and the music widget both use it.
struct MusicBars: View {
    var color: Color = Theme.color(.active)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 4 + 6 * (phase + 1) / 2)
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
