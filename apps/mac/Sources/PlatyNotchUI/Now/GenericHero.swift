import PlatyNotchKit
import SwiftUI

/// The hero for a live item whose widget draws none: its glyph at hero size, the title,
/// the subtitle and a live countdown or count-up.
struct GenericHero: View {
    let item: LiveItem

    var body: some View {
        if case .activity(let activity) = item.source {
            ActivityHero(activity: activity, action: nil)
        } else {
            HeroLayout(title: item.title, subtitle: item.subtitle, action: nil) {
                HeroGlyph(glyph: .symbol("sparkles"), tint: .neutral)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// A countdown ("4:12"), a count-up, or "in 8 min" before a meeting, in the display
/// style; it ticks only while the panel is shown (`panelTicking`); nothing without a date.
struct HeroClock: View {
    enum Style { case clock, minutesUntil }

    let countdownTo: Date?
    let countUpFrom: Date?
    var style: Style = .clock
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        if countdownTo != nil || countUpFrom != nil {
            if ticking {
                TimelineView(.periodic(from: .now, by: style == .clock ? 1 : 15)) { ctx in label(at: ctx.date) }
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
            .accessibilityLabel(Self.spoken(countdownTo: countdownTo, countUpFrom: countUpFrom, style: style, now: now))
    }

    private func text(at now: Date) -> String {
        if let end = countdownTo {
            if style == .minutesUntil { return NowSummaryLine.inMinutes(to: end, now: now) ?? "now" }
            return TodayFormat.clock(max(end.timeIntervalSince(now), 0))
        }
        if let start = countUpFrom { return TodayFormat.clock(now.timeIntervalSince(start).rounded(.down)) }
        return ""
    }

    /// What VoiceOver says: "4 minutes 12 seconds left", "1 hour 2 minutes elapsed",
    /// "starts in 8 minutes".
    static func spoken(countdownTo: Date?, countUpFrom: Date?, style: Style, now: Date) -> String {
        if let end = countdownTo {
            let left: TimeInterval = max(end.timeIntervalSince(now), 0)
            if style == .minutesUntil {
                let minutes = Int((left / 60).rounded(.up))
                return minutes <= 0 ? "starting now" : "starts in \(minutes) minute\(minutes == 1 ? "" : "s")"
            }
            return duration(left.rounded(.up)) + " left"
        }
        if let start = countUpFrom { return duration(now.timeIntervalSince(start).rounded(.down)) + " elapsed" }
        return ""
    }

    /// "1 hour 2 minutes 5 seconds", leaving out zero parts ("0 seconds" alone).
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        let parts: [(Int, String)] = [(total / 3600, "hour"), ((total % 3600) / 60, "minute"), (total % 60, "second")]
        let words = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return words.isEmpty ? "0 seconds" : words.joined(separator: " ")
    }
}

/// A hero's one primary control: a title from `HeroPrimary` or `AgentRowAction`.
struct HeroAction {
    let title: String
    let systemImage: String
    let run: () -> Void
}

/// The shared hero layout: a leading visual (glyph, artwork or Platy), then a text column
/// with the title (the column's full width), a secondary line, and a bottom row with an
/// optional big value (a countdown) and at most one primary control. Text truncates; the
/// control never leaves the frame. The title takes two lines only when there is no value.
struct HeroLayout<Leading: View, Value: View>: View {
    /// The coordinate space the primary control's frame is reported in (`HeroActionFrameKey`).
    static var space: String { "heroLayout" }

    let title: String
    let subtitle: String?
    let action: HeroAction?
    /// False when `value` draws nothing (the title may then wrap to two lines).
    let hasValue: Bool
    let leading: Leading
    let value: Value
    @Environment(\.heroPosition) private var position
    @Environment(\.morph) private var morph
    @Environment(\.heroItemID) private var heroItemID

    init(title: String, subtitle: String?, action: HeroAction?, hasValue: Bool = true,
         @ViewBuilder leading: () -> Leading, @ViewBuilder value: () -> Value) {
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.hasValue = hasValue
        self.leading = leading()
        self.value = value()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.l) {
            leading
                // The pill's trailing glyph grows into this one (same live item).
                .morph(heroItemID.flatMap { id in morph?.liveID == id ? MorphID.live(id) : nil })
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: title)
                    .font(DS.font(TypeScale.title))
                    .lineLimit(hasValue ? 1 : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(DS.font(TypeScale.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if hasValue || action != nil {
                    HStack(alignment: .center, spacing: 0) {
                        value
                        Spacer(minLength: Space.s)
                        if let action { button(action) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: Self.space)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(position.map { "Live item \($0), \(title)" } ?? "Live item, \(title)")
    }

    private func button(_ action: HeroAction) -> some View {
        Button(action: action.run) {
            Label(action.title, systemImage: action.systemImage)
                .font(DS.font(TypeScale.body).weight(.semibold))
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 2)
                .lineLimit(1)
                .fixedSize()
        }
        .buttonStyle(HeroPrimaryButtonStyle())
        .layoutPriority(1)
        .accessibilityLabel(action.title)
        .background(GeometryReader { g in
            Color.clear.preference(key: HeroActionFrameKey.self, value: g.frame(in: .named(Self.space)))
        })
    }
}

extension HeroLayout where Value == EmptyView {
    init(title: String, subtitle: String?, action: HeroAction?, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, action: action, hasValue: false, leading: leading,
                  value: { EmptyView() })
    }
}

/// The primary control's frame in `HeroLayout.space` (fit tests).
struct HeroActionFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = nextValue() ?? value
    }
}

extension EnvironmentValues {
    /// "2 of 3" for the hero inside `HeroFrame` (VoiceOver: "Live item 2 of 3, …").
    @Entry var heroPosition: String? = nil
}

/// The hero's one primary control: Platy teal with a black label in dark, the deep teal
/// with a white label in light (both above 4.5:1).
struct HeroPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        let dark: Bool = scheme != .light
        let fill: Color = dark ? DS.teal : Color(StateTone.working.rgb(dark: false))
        configuration.label
            .foregroundStyle(dark ? Color.black : Color.white)
            .padding(.horizontal, Space.s)
            .padding(.vertical, Space.xs)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
    }

    /// The label and fill colours for a scheme (contrast tests).
    static func colors(dark: Bool) -> (label: RGB, fill: RGB) {
        dark ? (RGB(hex: 0x000000), Brand.teal) : (RGB(hex: 0xFFFFFF), StateTone.working.rgb(dark: false))
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
        let hasValue: Bool = activity.countdownTo != nil || activity.countUpFrom != nil || activity.trailing != nil
        HeroLayout(title: activity.title ?? activity.accessibilityLabel ?? activity.widgetID,
                   subtitle: activity.subtitle, action: action, hasValue: hasValue) {
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
        .accessibilityElement(children: .combine)
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
