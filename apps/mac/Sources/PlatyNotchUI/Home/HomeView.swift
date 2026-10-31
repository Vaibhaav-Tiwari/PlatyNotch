import PlatyNotchKit
import SwiftUI

/// What Home shows now, gathered from the models (pure data, so tests read it).
struct HomeData {
    var chips: [LiveChip] = []
    var overflow = 0
    /// The Today card's bottom part.
    var next: TodayNext = .noCalendar(days: [])
    /// The drop targets while a file drag is near; nil otherwise.
    var drop: (shelfOn: Bool, airDrop: Bool)?

    /// The Today card's first-run sample (was a chip).
    static let sample = TodayNext.sample(title: "This is Home", subtitle: "Every tool is one click away in the dock")

    /// Collects Home's data. Calendar is read only while its widget is on and access is
    /// already granted (no prompts, ever). `tourSample` is the first run's "Try it": the
    /// Today card shows it.
    @MainActor
    static func make(today: TodayServices, widgets: WidgetRegistry, settings: HomeSettings,
                     tourSample: LiveActivity?, now: Date, dropping: Bool, airDrop: Bool = ShelfActions.canAirDrop,
                     calendar: Calendar = .current, locale: Locale = .current) -> HomeData {
        var data = HomeData()
        let time = widgets.isEnabled(TimeWidget.widgetID) ? widgets.widget(TimeWidget.widgetID) as? TimeWidget : nil
        let shelf = widgets.isEnabled(ShelfWidget.widgetID) ? widgets.widget(ShelfWidget.widgetID) as? ShelfWidget : nil
        let focus: FocusTimer? = widgets.isEnabled(FocusWidget.widgetID) ? today.focus.timer : nil
        let live = LiveChips.chips(focus: focus, timers: time?.state.timers ?? [], shelfCount: shelf?.items.count ?? 0,
                                   now: now)
        data.chips = live.shown
        data.overflow = live.overflow
        if tourSample != nil {
            data.next = sample
        } else {
            let calendarOn: Bool = widgets.isEnabled(MeetingWidget.widgetID) && today.calendar.access == .granted
            data.next = TodayNextModel.make(meetings: calendarOn ? today.calendar.meetings : nil,
                                            daysWithEvents: calendarOn ? today.calendar.weekDaysWithEvents : [],
                                            now: now, calendar: calendar, locale: locale)
        }
        if dropping {
            data.drop = (shelf != nil, airDrop)
        }
        return data
    }
}

/// The reported natural height of Home's body, which the controller turns into the panel's
/// height (`PanelLayout.expandedHeight(forBody:)`).
struct HomeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) { value = nextValue() ?? value }
}

/// Home (Island spec 3): the Now Playing card beside the Today card (1.25 : 1, 10 apart,
/// always the same height), then (until the dock) the live chips and the command line.
/// While a file drag nears the notch the cards become drop targets.
struct HomeView: View {
    let today: TodayServices
    let widgets: WidgetRegistry
    let settings: HomeSettings
    var tourSample: LiveActivity?
    var fixedNow: Date?
    /// The drag is near: show the drop targets (`.peek(.drop)`).
    var dropping = false
    /// Which drop target the pointer is over.
    var dropHover: DropTargetsView.Zone?
    var onOpenTool: (String) -> Void = { _ in }
    /// The command line below the cards.
    var commandLine: AnyView = AnyView(EmptyView())
    /// The command line has focus: the cards step aside so its rows (everything it can do,
    /// or what the text suggests) have the room, like Spotlight. Esc brings them back.
    var commandFocused = false

    /// The cards Home draws, in order (tests).
    static func ids(_ data: HomeData) -> [String] {
        data.drop == nil ? ["nowPlaying", "today"] : ["drop"]
    }

    /// The weather widget while it is on (the Today card's sky), else nil.
    @MainActor
    static func weather(_ widgets: WidgetRegistry) -> WeatherWidget? {
        widgets.isEnabled(WeatherWidget.widgetID) ? widgets.widget(WeatherWidget.widgetID) as? WeatherWidget : nil
    }

    /// Everything Home prints, in reading order (tests).
    @MainActor
    static func texts(_ data: HomeData, nowPlaying: NowPlaying, weather: WeatherWidget? = nil,
                      now: Date = Date()) -> [String] {
        var out: [String] = []
        if let drop = data.drop {
            out += data.chips.map(\.text)
            if data.overflow > 0 { out.append("+\(data.overflow)") }
            return out + DropTargetsView.titles(shelfOn: drop.shelfOn, airDrop: drop.airDrop)
        }
        let hour: Int = Calendar.current.component(.hour, from: now)
        let empty = MusicEmptyState.make(last: nowPlaying.lastPlayed, recents: nowPlaying.recents, hour: hour)
        out += NowPlayingCard.texts(nowPlaying, empty: empty)
        out += TodayCard.texts(sky: SkyContent.of(weather, now: now)?.texts, next: data.next)
        out += data.chips.map(\.text)
        if data.overflow > 0 { out.append("+\(data.overflow)") }
        return out
    }

    var body: some View {
        TickingNow(fixed: fixedNow) { now in
            let data = HomeData.make(today: today, widgets: widgets, settings: settings, tourSample: tourSample,
                                     now: now, dropping: dropping)
            content(data)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func content(_ data: HomeData) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.dockTop) {
            if let drop = data.drop {
                if !data.chips.isEmpty {
                    ChipsRow(chips: data.chips, overflow: data.overflow, onOpen: onOpenTool)
                }
                DropTargetsView(shelfOn: drop.shelfOn, airDrop: drop.airDrop, hovered: dropHover)
            } else if commandFocused {
                commandLine
            } else {
                TwoColumns(ratio: HomeMetrics.nowPlayingRatio, gap: HomeMetrics.cardGap) {
                    NowPlayingCard(nowPlaying: today.nowPlaying, recents: today.nowPlaying.recents, fixedNow: fixedNow)
                    TodayCard(weather: Self.weather(widgets), next: data.next, fixedNow: fixedNow,
                              onConnectCalendar: { today.calendar.openSettings() })
                }
                if !data.chips.isEmpty {
                    ChipsRow(chips: data.chips, overflow: data.overflow, onOpen: onOpenTool)
                }
                commandLine
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: HomeHeightKey.self, value: g.size.height)
        })
    }
}

/// A 1 px line at white 0.10 (spec 5.1).
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// Two columns 1.15 : 1 with a gap, as tall as the taller one.
struct TwoColumns: Layout {
    let ratio: CGFloat
    let gap: CGFloat

    private func widths(_ total: CGFloat) -> (CGFloat, CGFloat) {
        let usable: CGFloat = max(0, total - gap)
        let left: CGFloat = usable * ratio / (ratio + 1)
        return (left, usable - left)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total: CGFloat = proposal.width ?? (PanelLayout.expandedWidth - 2 * Space.panelSide)
        let (l, r) = widths(total)
        var h: CGFloat = 0
        if subviews.count == 2 {
            h = max(subviews[0].sizeThatFits(ProposedViewSize(width: l, height: nil)).height,
                    subviews[1].sizeThatFits(ProposedViewSize(width: r, height: nil)).height)
        }
        return CGSize(width: total, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (l, r) = widths(bounds.width)
        guard subviews.count == 2 else { return }
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: l, height: bounds.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + l + gap, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: r, height: bounds.height))
    }
}
