import PlatyNotchKit
import SwiftUI

/// The resting panel (spec 6.1, 6.7). The agents ear holds Platy (the aggregate mood) at
/// its outer edge and the agent dots toward the notch, coloured by each session's agent
/// with the state as the dot's motion, then "+n" (a badge on Platy when the label has no
/// room, `PlatyEarFit`). The live ear holds the connection glyph, else the approval badge,
/// else the top live item's glyph and text, then up to two indicator dots for the next
/// live items (`PillContent`, `LiveEarFit`). `liveSide` says which ear is the live one.
/// On a notch the ears sit beside the camera housing.
struct CompactPill: View {
    let content: PillContent
    let connection: ConnectionState
    let hasNotch: Bool
    /// Width of the physical notch (0 without one).
    let notchWidth: CGFloat
    var liveSide: LiveSide = .right
    /// Room for each ear's content (`PanelLayout.liveEarWidth`); what does not fit is
    /// dropped or truncated, never drawn past the ear.
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
        .accessibilityLabel(Self.accessibilitySummary(content: content, connection: connection, platy: platy))
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

    private var liveEar: some View {
        LiveEarView(content: content, connection: connection, earWidth: earWidth)
    }

    private var agentsEar: some View {
        let dots: PillDots = content.dots
        let pad: CGFloat = PanelLayout.pillPadding(hasNotch: hasNotch)
        let fit: PlatyEarFit? = platy.map { _ in
            PlatyEarFit(earWidth: earWidth, dots: dots.dots.count, overflow: dots.overflow, outerPadding: pad)
        }
        let shown: Int = fit?.dots ?? dots.dots.count
        let count: Int = fit?.overflowCount ?? dots.overflow
        let badge: Bool = (fit?.badge ?? false) && count > 0
        // The agents ear is left of the notch when the live ear is on the right. Platy sits
        // at the ear's outer edge, the dots run toward the notch (mirrored on the right).
        let earOnLeft: Bool = liveSide == .right
        let kept: [PillDots.Dot] = Array(dots.dots.prefix(shown))
        let ordered: [PillDots.Dot] = earOnLeft ? kept : kept.reversed()
        return HStack(spacing: PlatyEarFit.spacing) {
            if earOnLeft {
                platyGlyph(count: count, badge: badge, dots: shown, earOnLeft: true)
                dotViews(ordered)
                overflowLabel(count, badge: badge)
            } else {
                overflowLabel(count, badge: badge)
                dotViews(ordered)
                platyGlyph(count: count, badge: badge, dots: shown, earOnLeft: false)
            }
        }
        // With a badge, the content sits against the notch so the badge has the rest.
        .frame(width: badge ? earWidth : nil, alignment: earOnLeft ? .trailing : .leading)
    }

    private func dotViews(_ dots: [PillDots.Dot]) -> some View {
        ForEach(dots, id: \.key) { dot in
            AgentDot(color: DS.agentNSColor(dot.agent), style: dot.style)
        }
    }

    @ViewBuilder private func overflowLabel(_ count: Int, badge: Bool) -> some View {
        if count > 0, !badge {
            Text("+\(count)")
                .font(DS.font(TypeScale.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }

    @ViewBuilder private func platyGlyph(count: Int, badge: Bool, dots: Int, earOnLeft: Bool) -> some View {
        if let platy {
            PlatyView(mood: platy, size: PlatyEarFit.platy, morphID: MorphID.platy)
                .overlay(alignment: earOnLeft ? .bottomTrailing : .bottomLeading) {
                    // From Platy's centre outward, across the ear's free room and the
                    // pill's outer padding; never over a dot, the notch or past the pill's
                    // edge (`PlatyEarFit.badgeOffset`).
                    if badge {
                        let start: CGFloat = badgeStart(count, dots: dots)
                        OverflowBadge(count: count)
                            .offset(x: earOnLeft ? -start : start)
                    }
                }
        }
    }

    /// The badge's start outward from Platy's notch-side edge.
    private func badgeStart(_ count: Int, dots: Int) -> CGFloat {
        let pad: CGFloat = PanelLayout.pillPadding(hasNotch: hasNotch)
        let width: CGFloat = OverflowBadge.width(count)
        let dotsWidth: CGFloat = CGFloat(dots) * PlatyEarFit.dot
        let start: CGFloat = PlatyEarFit.badgeOffset(earWidth: earWidth, outerPadding: pad, badgeWidth: width,
                                                     dotsWidth: dotsWidth)
        return start - dotsWidth
    }

    /// What VoiceOver reads for the pill: the sessions, Platy's mood, approvals, the
    /// connection, the top live item and every indicator.
    static func accessibilitySummary(content: PillContent, connection: ConnectionState, platy: PlatyMood?) -> String {
        var parts: [String] = []
        parts.append(content.sessionsSummary)
        if let platy { parts.append(platy.accessibilityLabel) }
        if content.approvalCount > 0 { parts.append("\(content.approvalCount) waiting for approval") }
        if connection != .connected { parts.append("reconnecting to core") }
        let items: [LiveActivity] = [content.trailing].compactMap { $0 } + content.indicators
        for a in items {
            parts.append(a.accessibilityLabel ?? a.title ?? a.trailing ?? a.widgetID)
        }
        return parts.joined(separator: ", ")
    }
}

/// The live ear: the connection glyph, else the approval badge (it always wins), else the
/// top live item's glyph and trailing text, then up to two 6 pt indicator dots tinted by
/// each next item's tint. Never wider than `earWidth` (`LiveEarFit`).
struct LiveEarView: View {
    let content: PillContent
    let connection: ConnectionState
    let earWidth: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.morph) private var morph

    var body: some View {
        if connection != .connected {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.color(.attention))
        } else if content.approvalCount > 0 {
            Text("\(content.approvalCount)")
                .font(DS.font(TypeScale.caption, design: .rounded).weight(.bold))
                .foregroundStyle(.black)   // on the amber badge, every scheme
                .frame(minWidth: 14, minHeight: 14)
                .background(Theme.needsYouFill, in: Capsule())
        } else if let top = content.trailing {
            let fit = LiveEarFit(earWidth: earWidth, hasTrailing: Self.hasTrailing(top),
                                 indicators: content.indicators.count)
            HStack(spacing: LiveEarFit.spacing) {
                LiveGlyphView(glyph: top.glyph, tint: top.tint)
                    // Grows into the hero's glyph when the hero shows the same item.
                    .morph(morph?.liveID == top.id ? MorphID.live(top.id) : nil)
                    .frame(maxWidth: LiveEarFit.glyph)
                if fit.trailingWidth > 0 {
                    LiveTrailing(activity: top)
                        .frame(maxWidth: fit.trailingWidth, alignment: .leading)
                }
                ForEach(content.indicators.prefix(fit.indicatorsShown), id: \.id) { item in
                    Circle()
                        .fill(Theme.tint(item.tint, scheme: scheme))
                        .frame(width: LiveEarFit.indicator, height: LiveEarFit.indicator)
                }
            }
            .lineLimit(1)
        }
    }

    static func hasTrailing(_ a: LiveActivity) -> Bool {
        a.countdownTo != nil || a.countUpFrom != nil || a.trailing != nil
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
            // Level with Platy's bottom (not below it), so the mood's cue still reads.
            .offset(y: 0)
    }
}

/// A live activity's glyph, about 12 pt.
struct LiveGlyphView: View {
    let glyph: LiveGlyph
    let tint: LiveTint
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                Image(systemName: name).font(DS.font(TypeScale.caption).weight(.semibold))
            case .musicBars:
                MusicBars(color: Theme.tint(tint, scheme: scheme))
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
        .foregroundStyle(Theme.tint(tint, scheme: scheme))
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
