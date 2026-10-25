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
    /// `LiveArbiter.pick` of the running widgets' activities (agents have the other ear).
    var primary: LiveActivity?
    var bubble: LiveActivity?
    var liveSide: LiveSide = .right
    /// Room for the live ear's content (`PanelLayout.liveEarWidth`); what does not fit is
    /// dropped or truncated (`LiveEarFit`), never drawn past the ear.
    var earWidth: CGFloat = .infinity
    /// Platy's mood, drawn first in the agents ear with the dots that fit beside it
    /// (`PlatyEarFit`); nil = the plain look (Appearance › Show Platy off).
    var platy: PlatyMood?

    var body: some View {
        HStack(spacing: 0) {
            ear(liveSide == .left ? AnyView(liveEar) : AnyView(agentsEar), alignment: .leading)
            if hasNotch { Color.clear.frame(width: notchWidth) }
            ear(liveSide == .left ? AnyView(agentsEar) : AnyView(liveEar), alignment: .trailing)
        }
        .padding(.horizontal, PanelLayout.pillPadding(hasNotch: hasNotch))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the PlatyNotch panel")
    }

    /// One ear's frame. An empty ear (nothing live) still takes its room: a frame around
    /// empty content collapses, which let the agents ear slide under the camera housing.
    /// Beside a notch each ear is exactly `earWidth`.
    @ViewBuilder private func ear(_ content: AnyView, alignment: Alignment) -> some View {
        let placed = ZStack(alignment: hasNotch ? .center : alignment) {
            Color.clear
            content
        }
        if hasNotch, earWidth.isFinite {
            placed.frame(width: earWidth)
        } else {
            placed.frame(maxWidth: .infinity)
        }
    }

    private var agentsEar: some View {
        let fit = platy.map { _ in PlatyEarFit(earWidth: earWidth, dots: dots.dots.count, overflow: dots.overflow) }
        let shown: Int = fit?.dots ?? dots.dots.count
        let count: Int = fit?.overflowCount ?? dots.overflow
        let badge: Bool = fit?.badge ?? false
        // The agents ear is left of the notch when the live ear is on the right.
        let earOnLeft: Bool = liveSide == .right
        return HStack(spacing: 4) {
            if let platy {
                PlatyView(mood: platy, size: PlatyEarFit.platy)
                    .overlay(alignment: earOnLeft ? .bottomTrailing : .bottomLeading) {
                        // From Platy's centre outward, across the ear's free room (no dots
                        // are drawn with a badge) and the pill's outer padding; never over
                        // the notch or past the pill's edge (`PlatyEarFit.badgeOffset`).
                        if badge, count > 0 {
                            let start: CGFloat = badgeStart(count)
                            OverflowBadge(count: count)
                                .offset(x: earOnLeft ? -start : start)
                        }
                    }
            }
            ForEach(dots.dots.prefix(shown), id: \.key) { AgentDot(tone: $0.tone) }
            if count > 0, !badge {
                Text("+\(count)")
                    .font(DS.font(TypeScale.caption, design: .rounded).weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        // With a badge, Platy sits against the notch so the badge has the rest.
        .frame(width: badge && count > 0 ? earWidth : nil, alignment: earOnLeft ? .trailing : .leading)
    }

    /// The badge's start, outward from the notch edge (Platy's notch-side edge).
    private func badgeStart(_ count: Int) -> CGFloat {
        let pad: CGFloat = PanelLayout.pillPadding(hasNotch: hasNotch)
        let width: CGFloat = OverflowBadge.width(count)
        return PlatyEarFit.badgeOffset(earWidth: earWidth, outerPadding: pad, badgeWidth: width)
    }

    @ViewBuilder private var liveEar: some View {
        if connection != .connected {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.color(.attention))
        } else if approvalCount > 0 {
            Text("\(approvalCount)")
                .font(DS.font(TypeScale.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.black)   // on the amber badge, every scheme
                .frame(minWidth: 14, minHeight: 14)
                .background(Theme.needsYouFill, in: Capsule())
        } else if let primary {
            let fit = LiveEarFit(earWidth: earWidth, hasTrailing: Self.hasTrailing(primary), hasBubble: bubble != nil)
            HStack(spacing: LiveEarFit.spacing) {
                LiveGlyphView(glyph: primary.glyph, tint: primary.tint)
                    .frame(maxWidth: LiveEarFit.glyph)
                if fit.trailingWidth > 0 {
                    LiveTrailing(activity: primary)
                        .frame(maxWidth: fit.trailingWidth, alignment: .leading)
                }
                if fit.showsBubble, let bubble {
                    LiveGlyphView(glyph: bubble.glyph, tint: bubble.tint)
                        .scaleEffect(0.75)
                        .frame(width: LiveEarFit.bubble, height: LiveEarFit.bubble)
                        .background(Theme.card, in: Circle())
                }
            }
            .lineLimit(1)
        }
    }

    private static func hasTrailing(_ a: LiveActivity) -> Bool {
        a.countdownTo != nil || a.countUpFrom != nil || a.trailing != nil
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        let live = dots.dots.count + dots.overflow
        parts.append(live == 1 ? "1 agent session" : "\(live) agent sessions")
        if let platy { parts.append(platy.accessibilityLabel) }
        if approvalCount > 0 { parts.append("\(approvalCount) waiting for approval") }
        if connection != .connected { parts.append("reconnecting to core") }
        for a in [primary, bubble].compactMap({ $0 }) {
            if let label = a.accessibilityLabel { parts.append(label) }
        }
        return parts.joined(separator: ", ")
    }
}

/// "+n" ("99+" above 99) beside Platy when the ear has no room for it after the dots.
private struct OverflowBadge: View {
    let count: Int

    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: TypeScale.minimum, weight: .bold)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: rounded, size: TypeScale.minimum) ?? base
    }()

    /// The drawn width: the text, rounded up, and the capsule's padding.
    static func width(_ count: Int) -> CGFloat {
        let text = NSAttributedString(string: PlatyEarFit.badgeText(count), attributes: [.font: font])
        return text.size().width.rounded(.up) + 2 * PlatyEarFit.badgePadding
    }

    var body: some View {
        Text(verbatim: PlatyEarFit.badgeText(count))
            .font(DS.font(TypeScale.caption, design: .rounded).weight(.bold))
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, PlatyEarFit.badgePadding)
            .background(Color(white: 0.25), in: Capsule())
            .offset(y: 2)
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
                Image(systemName: name).font(DS.font(TypeScale.caption).weight(.semibold))
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
                Text(verbatim: s).font(DS.font(TypeScale.caption, design: .rounded).weight(.semibold))
            }
        }
        .foregroundStyle(Theme.tint(tint))
        .accessibilityHidden(true)
    }
}

/// The text after the glyph: a live m:ss countdown (or count-up, a stopwatch) once a
/// second, only while the panel is really shown (not while hidden or suppressed over full
/// screen), or `trailing`.
private struct LiveTrailing: View {
    let activity: LiveActivity
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        if activity.countdownTo != nil || activity.countUpFrom != nil {
            if ticking {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    label(text(at: ctx.date))
                }
            } else {
                label(text(at: Date()))
            }
        } else if let text = activity.trailing {
            label(text)
        }
    }

    private func text(at now: Date) -> String {
        if let end = activity.countdownTo { return TodayFormat.clock(end.timeIntervalSince(now)) }
        if let start = activity.countUpFrom { return TodayFormat.clock(now.timeIntervalSince(start).rounded(.down)) }
        return ""
    }

    private func label(_ s: String) -> some View {
        Text(verbatim: s)
            .font(DS.font(TypeScale.caption, design: .rounded).weight(.semibold))
            .monospacedDigit()
            .truncationMode(.tail)
            .foregroundStyle(.secondary)
    }
}
