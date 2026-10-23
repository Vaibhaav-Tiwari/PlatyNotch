import PlatyNotchKit
import SwiftUI

/// The resting panel: agent dots on the left, music bars (or a status badge) on the right.
/// On a notch the two sides sit in the ears beside the camera housing.
struct CompactPill: View {
    let dots: PillDots
    let approvalCount: Int
    let connection: ConnectionState
    let hasNotch: Bool
    /// Width of the physical notch (0 without one).
    let notchWidth: CGFloat
    /// Fed by now playing (Plan 3 Task 8).
    var musicPlaying = false

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(maxWidth: .infinity, alignment: hasNotch ? .center : .leading)
            if hasNotch { Color.clear.frame(width: notchWidth) }
            trailing
                .frame(maxWidth: .infinity, alignment: hasNotch ? .center : .trailing)
        }
        .padding(.horizontal, hasNotch ? 6 : 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the PlatyNotch panel")
    }

    private var leading: some View {
        HStack(spacing: 4) {
            ForEach(dots.dots, id: \.key) { AgentDot(tone: $0.tone) }
            if dots.overflow > 0 {
                Text("+\(dots.overflow)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if connection != .connected {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.color(.attention))
        } else if approvalCount > 0 {
            Text("\(approvalCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .frame(minWidth: 14, minHeight: 14)
                .background(Theme.color(.attention), in: Capsule())
        } else if musicPlaying {
            MusicBars()
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        let live = dots.dots.count + dots.overflow
        parts.append(live == 1 ? "1 agent session" : "\(live) agent sessions")
        if approvalCount > 0 { parts.append("\(approvalCount) waiting for approval") }
        if connection != .connected { parts.append("reconnecting to core") }
        return parts.joined(separator: ", ")
    }
}

/// Three bars bouncing while music plays.
struct MusicBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = sin(t * (5 + Double(i) * 1.7) + Double(i))
                    Capsule()
                        .fill(Theme.color(.active))
                        .frame(width: 2.5, height: 4 + 6 * (phase + 1) / 2)
                }
            }
            .frame(height: 10, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}
