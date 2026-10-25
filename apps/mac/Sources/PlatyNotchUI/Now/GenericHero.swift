import PlatyNotchKit
import SwiftUI

/// The hero for a live item whose widget draws none: its glyph at hero size, the title,
/// the subtitle and a live countdown or count-up.
struct GenericHero: View {
    let item: LiveItem

    var body: some View {
        HeroLayout(title: item.title, subtitle: item.subtitle, action: nil) {
            if let activity {
                HeroGlyph(glyph: activity.glyph, tint: activity.tint)
            } else {
                HeroGlyph(glyph: .symbol("sparkles"), tint: .neutral)
            }
        } value: {
            if let activity {
                HeroClock(countdownTo: activity.countdownTo, countUpFrom: activity.countUpFrom)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var activity: LiveActivity? {
        if case .activity(let a) = item.source { return a }
        return nil
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

/// A hero's one primary control: a title from `HeroPrimary` or `AgentRowAction`.
struct HeroAction {
    let title: String
    let systemImage: String
    let run: () -> Void
}

/// The shared hero layout: a leading visual (glyph, artwork or Platy), the title, a
/// secondary line, an optional big value (a countdown) and at most one primary control.
/// Text truncates; the control never leaves the frame.
struct HeroLayout<Leading: View, Value: View>: View {
    let title: String
    let subtitle: String?
    let action: HeroAction?
    let leading: Leading
    let value: Value

    init(title: String, subtitle: String?, action: HeroAction?,
         @ViewBuilder leading: () -> Leading, @ViewBuilder value: () -> Value) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.leading = leading()
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            leading
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: title)
                    .font(DS.font(TypeScale.title))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(DS.font(TypeScale.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                value
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action: action.run) {
                    Label(action.title, systemImage: action.systemImage)
                        .font(DS.font(TypeScale.body).weight(.semibold))
                        .padding(.horizontal, Space.xs)
                        .padding(.vertical, 2)
                        .lineLimit(1)
                        .fixedSize()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                // The deeper teal in both themes: white text on it passes 4.5:1 (Platy teal does not).
                .tint(Color(StateTone.working.rgb(dark: false)))
                .layoutPriority(1)
                .accessibilityLabel(action.title)
            }
        }
    }
}

extension HeroLayout where Value == EmptyView {
    init(title: String, subtitle: String?, action: HeroAction?, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, action: action, leading: leading, value: { EmptyView() })
    }
}

/// A live glyph at hero size (a symbol, a progress ring or music bars).
struct HeroGlyph: View {
    let glyph: LiveGlyph
    let tint: LiveTint

    var body: some View {
        Group {
            switch glyph {
            case .symbol(let name):
                DS.icon(name, size: IconSize.hero).foregroundStyle(Theme.tint(tint))
            case .ring(let progress):
                ZStack {
                    Circle().stroke(.secondary.opacity(0.3), lineWidth: 4)
                    Circle().trim(from: 0, to: min(max(progress, 0), 1))
                        .stroke(Theme.tint(tint), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(4)
            case .musicBars:
                MusicBars(color: Theme.tint(tint))
            case .text(let s):
                Text(verbatim: s).font(DS.font(TypeScale.headline, design: .rounded)).lineLimit(1)
            case .agentDots:
                DS.icon("terminal", size: IconSize.hero).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// A hero for one live activity: its glyph, title, subtitle, a live countdown / count-up
/// (or its trailing text) and an optional primary control.
struct ActivityHero: View {
    let activity: LiveActivity
    let action: HeroAction?

    var body: some View {
        HeroLayout(title: activity.title ?? activity.accessibilityLabel ?? activity.widgetID,
                   subtitle: activity.subtitle, action: action) {
            HeroGlyph(glyph: activity.glyph, tint: activity.tint)
        } value: {
            if activity.countdownTo != nil || activity.countUpFrom != nil {
                HeroClock(countdownTo: activity.countdownTo, countUpFrom: activity.countUpFrom)
            } else if let trailing = activity.trailing {
                Text(verbatim: trailing)
                    .font(DS.font(TypeScale.display))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// A widget's hero: its top-ranked live activity (read in `body`, so the hero follows the
/// widget), with the primary control `action` gives for it. Nothing when none is live.
struct TopActivityHero: View {
    let activities: () -> [LiveActivity]
    let action: (LiveActivity) -> HeroAction?

    var body: some View {
        if let top = PriorityModel.rank(activities(), agents: nil, now: Date()).first,
           case .activity(let activity) = top.source {
            ActivityHero(activity: activity, action: action(activity))
        }
    }
}
