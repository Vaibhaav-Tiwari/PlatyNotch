import PlatyNotchKit
import SwiftUI

/// What Home shows now, gathered from the models (pure data, so tests read it).
struct HomeData {
    /// The dock's slots as they show now (badges, live states, off tools).
    var dock: [DockItemState] = []
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
                     calendar: Calendar = .current, locale: Locale = .current, dock: DockLayout = .standard,
                     toolTitles: [String: String] = [:], searchKey: String? = CommandHotKey.presets.first?.display)
                     -> HomeData {
        var data = HomeData()
        let time = widgets.isEnabled(TimeWidget.widgetID) ? widgets.widget(TimeWidget.widgetID) as? TimeWidget : nil
        let shelf = widgets.isEnabled(ShelfWidget.widgetID) ? widgets.widget(ShelfWidget.widgetID) as? ShelfWidget : nil
        let focus: FocusTimer? = widgets.isEnabled(FocusWidget.widgetID) ? today.focus.timer : nil
        // The widget's own service (the app's shared one, except in renders and tests).
        let reminders: RemindersService = (widgets.widget(RemindersWidget.widgetID) as? RemindersWidget)?.reminders
            ?? today.reminders
        let due: Int = widgets.isEnabled(RemindersWidget.widgetID) && reminders.access == .granted
            ? RemindersDue.count(reminders.items, now: now, calendar: calendar) : 0
        let enabled: Set<String> = Set(widgets.widgets.map(\.id).filter { widgets.isEnabled($0) })
        data.dock = DockState.items(layout: dock, toolTitles: toolTitles, enabledWidgets: enabled, focus: focus,
                                    timers: time?.state.timers ?? [], stopwatch: time?.state.stopwatch,
                                    remindersDue: due, shelfCount: shelf?.items.count ?? 0, searchKey: searchKey,
                                    now: now)
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
/// always the same height), 12 pt, then the dock. While a file drag nears the notch the
/// drop box takes the cards' and the dock's place.
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
    /// A dock slot was clicked.
    var onOpen: (DockSlot) -> Void = { _ in }
    var dockLayout: DockLayout = .standard
    /// Non-core tools available now, by tool id (a dock slot for a missing one drops out).
    var toolTitles: [String: String] = [:]
    /// The global search shortcut's display ("⌥⌘K"); nil: off ("Search").
    var searchKey: String? = CommandHotKey.presets.first?.display
    /// Minimal: the dock folded into one Search slot.
    var foldedDock = false

    /// The cards Home draws, in order (tests).
    static func ids(_ data: HomeData) -> [String] {
        data.drop == nil ? ["nowPlaying", "today", "dock"] : ["drop"]
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
        if let drop = data.drop { return DropTargetsView.titles(shelfOn: drop.shelfOn, airDrop: drop.airDrop) }
        let hour: Int = Calendar.current.component(.hour, from: now)
        let empty = MusicEmptyState.make(last: nowPlaying.lastPlayed, recents: nowPlaying.recents, hour: hour)
        var out: [String] = NowPlayingCard.texts(nowPlaying, empty: empty)
        out += TodayCard.texts(sky: SkyContent.of(weather, now: now)?.texts, next: data.next)
        for item in data.dock {
            out.append(item.label)
            if let badge = item.badge { out.append(badge) }
        }
        return out
    }

    var body: some View {
        TickingNow(fixed: fixedNow) { now in
            let data = HomeData.make(today: today, widgets: widgets, settings: settings, tourSample: tourSample,
                                     now: now, dropping: dropping, dock: dockLayout, toolTitles: toolTitles,
                                     searchKey: searchKey)
            content(data, now: now)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func content(_ data: HomeData, now: Date) -> some View {
        VStack(alignment: .leading, spacing: HomeMetrics.dockTop) {
            if let drop = data.drop {
                DropTargetsView(shelfOn: drop.shelfOn, airDrop: drop.airDrop, hovered: dropHover)
            } else {
                TwoColumns(ratio: HomeMetrics.nowPlayingRatio, gap: HomeMetrics.cardGap) {
                    NowPlayingCard(nowPlaying: today.nowPlaying, recents: today.nowPlaying.recents, fixedNow: fixedNow)
                    TodayCard(weather: Self.weather(widgets), next: data.next, fixedNow: now,
                              onConnectCalendar: { today.calendar.openSettings() })
                }
                DockView(items: data.dock, folded: foldedDock, onOpen: onOpen)
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
