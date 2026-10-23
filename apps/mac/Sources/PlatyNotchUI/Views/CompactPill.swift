import PlatyNotchKit
import SwiftUI

/// The resting panel. One ear holds the agent dots; the other (the live ear) holds the
/// approval badge, which always wins, else the arbiter's primary live activity (glyph and
/// trailing text) with the second activity as a small bubble. `liveSide` says which ear
/// is the live one. On a notch the ears sit beside the camera housing.
struct CompactPill: View {
    let dots: PillDots
    let approvalCount: Int
    let connection: ConnectionState
    let hasNotch: Bool
    /// Width of the physical notch (0 without one).
    let notchWidth: CGFloat
    /// `LiveArbiter.pickForEar` of the running widgets' activities.
    var primary: LiveActivity?
    var bubble: LiveActivity?
    var liveSide: LiveSide = .right

    var body: some View {
        HStack(spacing: 0) {
            (liveSide == .left ? AnyView(liveEar) : AnyView(agentsEar))
                .frame(maxWidth: .infinity, alignment: hasNotch ? .center : .leading)
            if hasNotch { Color.clear.frame(width: notchWidth) }
            (liveSide == .left ? AnyView(agentsEar) : AnyView(liveEar))
                .frame(maxWidth: .infinity, alignment: hasNotch ? .center : .trailing)
        }
        .padding(.horizontal, hasNotch ? 6 : 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the PlatyNotch panel")
    }

    private var agentsEar: some View {
        HStack(spacing: 4) {
            ForEach(dots.dots, id: \.key) { AgentDot(tone: $0.tone) }
            if dots.overflow > 0 {
                Text("+\(dots.overflow)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var liveEar: some View {
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
        } else if let primary {
            HStack(spacing: 4) {
                LiveGlyphView(glyph: primary.glyph, tint: primary.tint)
                LiveTrailing(activity: primary)
                if let bubble {
                    LiveGlyphView(glyph: bubble.glyph, tint: bubble.tint)
                        .scaleEffect(0.75)
                        .frame(width: 14, height: 14)
                        .background(Theme.card, in: Circle())
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        let live = dots.dots.count + dots.overflow
        parts.append(live == 1 ? "1 agent session" : "\(live) agent sessions")
        if approvalCount > 0 { parts.append("\(approvalCount) waiting for approval") }
        if connection != .connected { parts.append("reconnecting to core") }
        for a in [primary, bubble].compactMap({ $0 }) {
            if let label = a.accessibilityLabel { parts.append(label) }
        }
        return parts.joined(separator: ", ")
    }
}

/// A live activity's glyph, about 12 pt.
struct LiveGlyphView: View {
    let glyph: LiveGlyph
    let tint: LiveTint

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name).font(.system(size: 10, weight: .semibold))
            case .musicBars:
                MusicBars(color: Theme.tint(tint))
            case .agentDots(let states):
                HStack(spacing: 2) {
                    ForEach(Array(states.prefix(3).enumerated()), id: \.offset) { _, s in
                        Circle().fill(Theme.color(AgentTone(s))).frame(width: 5, height: 5)
                    }
                }
            case .ring(let progress):
                ZStack {
                    Circle().stroke(.secondary.opacity(0.35), lineWidth: 2)
                    Circle().trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 10, height: 10)
            case .text(let s):
                Text(verbatim: s).font(.system(size: 10, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(Theme.tint(tint))
        .accessibilityHidden(true)
    }
}

/// The text after the glyph: a live m:ss countdown (once a second, only while the panel
/// is really shown: not while hidden or suppressed over full screen) or `trailing`.
private struct LiveTrailing: View {
    let activity: LiveActivity
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        if let end = activity.countdownTo {
            if ticking {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    label(TodayFormat.clock(end.timeIntervalSince(ctx.date)))
                }
            } else {
                label(TodayFormat.clock(end.timeIntervalSinceNow))
            }
        } else if let text = activity.trailing {
            label(text)
        }
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}
