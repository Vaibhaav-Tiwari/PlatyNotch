import PlatyNotchKit
import SwiftUI

/// The hero for a live item whose widget draws none: its glyph at hero size, the title,
/// the subtitle and a live countdown or count-up.
struct GenericHero: View {
    let item: LiveItem

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            glyph
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: item.title)
                    .font(DS.font(TypeScale.title))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = item.subtitle {
                    Text(verbatim: subtitle)
                        .font(DS.font(TypeScale.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let activity {
                    HeroClock(countdownTo: activity.countdownTo, countUpFrom: activity.countUpFrom)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var activity: LiveActivity? {
        if case .activity(let a) = item.source { return a }
        return nil
    }

    @ViewBuilder private var glyph: some View {
        if let activity {
            switch activity.glyph {
            case .symbol(let name):
                DS.icon(name, size: IconSize.hero).foregroundStyle(Theme.tint(activity.tint))
            case .ring(let progress):
                ZStack {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 4)
                    Circle().trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(Theme.tint(activity.tint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(4)
            case .musicBars:
                MusicBars(color: Theme.tint(activity.tint))
            case .text(let s):
                Text(verbatim: s).font(DS.font(TypeScale.headline, design: .rounded)).lineLimit(1)
            case .agentDots:
                DS.icon("terminal", size: IconSize.hero).foregroundStyle(.secondary)
            }
        } else {
            DS.icon("sparkles", size: IconSize.hero).foregroundStyle(.secondary)
        }
    }
}

/// A countdown ("4:12") or count-up in the display style, ticking once a second only
/// while the panel is shown (`panelTicking`); nothing without either date.
struct HeroClock: View {
    let countdownTo: Date?
    let countUpFrom: Date?
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        if countdownTo != nil || countUpFrom != nil {
            if ticking {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in label(at: ctx.date) }
            } else {
                label(at: Date())
            }
        }
    }

    private func label(at now: Date) -> some View {
        Text(verbatim: text(at: now))
            .font(DS.font(TypeScale.display))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
    }

    private func text(at now: Date) -> String {
        if let end = countdownTo { return TodayFormat.clock(max(end.timeIntervalSince(now), 0)) }
        if let start = countUpFrom { return TodayFormat.clock(now.timeIntervalSince(start).rounded(.down)) }
        return ""
    }
}
