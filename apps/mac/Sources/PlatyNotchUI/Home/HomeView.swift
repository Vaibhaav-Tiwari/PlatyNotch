import PlatyNotchKit
import SwiftUI

/// What Home shows now, gathered from the models (pure data, so tests read it).
struct HomeData {
    var chips: [LiveChip] = []
    var overflow = 0
    var column: HomeSettings.RightColumn = .upNext
    var rows: [UpNextRow] = []
    var noteLines: [String] = []
    var mailUnread: Int?
    var mailSubjects: [String] = []
    /// The drop targets while a file drag is near; nil otherwise.
    var drop: (shelfOn: Bool, airDrop: Bool)?

    /// Collects Home's data. Calendar and Reminders are read only while their widget is on
    /// and access is already granted (no prompts, ever). `tourSample` is the first run's
    /// "Try it" item, shown as a chip.
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
        if let tourSample, let title = tourSample.title {
            // At most four chips even with the sample: the one it pushes out joins "+n".
            data.chips.insert(LiveChip(kind: .sample, text: title, tone: nil), at: 0)
            if data.chips.count > LiveChips.maxShown {
                data.chips.removeLast()
                data.overflow += 1
            }
        }
        let notesOn: Bool = widgets.isEnabled(NotesWidget.widgetID)
        let mailOn: Bool = widgets.isEnabled(MailWidget.widgetID)
        data.column = settings.effectiveColumn(notesOn: notesOn, mailOn: mailOn)
        switch data.column {
        case .upNext:
            var items: [UpNextItem] = []
            if widgets.isEnabled(MeetingWidget.widgetID), today.calendar.access == .granted {
                items += today.calendar.meetings.filter { !$0.declined }.map {
                    UpNextItem(id: "e:" + $0.id, title: $0.title, date: $0.start, hasTime: true, isAllDay: $0.isAllDay,
                               kind: .event, end: $0.end)
                }
            }
            // The widget's own service (the app's shared one, except in renders and tests).
            let reminders: RemindersService = (widgets.widget(RemindersWidget.widgetID) as? RemindersWidget)?.reminders
                ?? today.reminders
            if widgets.isEnabled(RemindersWidget.widgetID), reminders.access == .granted {
                items += reminders.items.map {
                    UpNextItem(id: "r:" + $0.id, title: $0.title, date: $0.due, hasTime: $0.hasTime, isAllDay: false,
                               kind: .reminder)
                }
            }
            data.rows = UpNext.rows(items, now: now, calendar: calendar, locale: locale)
        case .notes:
            if let notes = widgets.widget(NotesWidget.widgetID) as? NotesWidget {
                data.noteLines = notes.tasks.filter { !$0.done }.prefix(3).map(\.text)
            }
        case .mail:
            if let mail = widgets.widget(MailWidget.widgetID) as? MailWidget, case .inbox(let inbox) = mail.phase {
                data.mailUnread = inbox.unread
                data.mailSubjects = inbox.latest.prefix(3).map(\.subject)
            }
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

/// Home (spec 2.2): live chips, the media block beside Up next (or Notes or Mail) with a
/// hairline between, a hairline, then the command line. While a file drag nears the notch
/// the body becomes drop targets.
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
    /// The command line below the hairline.
    var commandLine: AnyView = AnyView(EmptyView())
    /// The command line has focus: the columns step aside so its rows (everything it can do,
    /// or what the text suggests) have the room, like Spotlight. Esc brings them back.
    var commandFocused = false

    /// Everything Home prints, in reading order (tests).
    static func texts(_ data: HomeData, nowPlaying: NowPlaying) -> [String] {
        var out: [String] = []
        out += data.chips.map(\.text)
        if data.overflow > 0 { out.append("+\(data.overflow)") }
        if let drop = data.drop {
            return out + DropTargetsView.titles(shelfOn: drop.shelfOn, airDrop: drop.airDrop)
        }
        out.append(nowPlaying.title ?? MediaBlock.nothingPlaying)
        if let artist = nowPlaying.artist, nowPlaying.title != nil { out.append(artist) }
        switch data.column {
        case .upNext:
            out.append(UpNextColumn.label)
            if data.rows.isEmpty { out.append(UpNextColumn.empty) }
            for r in data.rows { out += [r.time, r.title] + (r.note.map { [$0] } ?? []) }
        case .notes:
            out.append(NotesColumn.label)
            out += data.noteLines.isEmpty ? [NotesColumn.empty] : data.noteLines
        case .mail:
            out.append(MailColumn.label)
            out += data.mailSubjects
        }
        return out
    }

    /// The identifier of the right column drawn (tests).
    static func columnID(_ data: HomeData) -> String {
        switch data.column {
        case .upNext: "upNext"
        case .notes: "notes"
        case .mail: "mail"
        }
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
        VStack(alignment: .leading, spacing: 12) {
            if !data.chips.isEmpty {
                ChipsRow(chips: data.chips, overflow: data.overflow, onOpen: onOpenTool)
            }
            if let drop = data.drop {
                DropTargetsView(shelfOn: drop.shelfOn, airDrop: drop.airDrop, hovered: dropHover)
            } else if commandFocused {
                commandLine
            } else {
                TwoColumns(ratio: HomeMetrics.columnRatio, gap: HomeMetrics.columnGap) {
                    MediaBlock(nowPlaying: today.nowPlaying, fixedNow: fixedNow)
                    rightColumn(data)
                }
                Hairline()
                commandLine
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in
            Color.clear.preference(key: HomeHeightKey.self, value: g.size.height)
        })
    }

    /// The right column with the hairline before it.
    @ViewBuilder private func rightColumn(_ data: HomeData) -> some View {
        Group {
            switch data.column {
            case .upNext: UpNextColumn(rows: data.rows)
            case .notes: NotesColumn(lines: data.noteLines)
            case .mail: MailColumn(unread: data.mailUnread, subjects: data.mailSubjects)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1)
                .offset(x: -HomeMetrics.columnGap / 2)
                .accessibilityHidden(true)
        }
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
