import PlatyNotchKit
import SwiftUI

/// The Time widget's tile: Timers, Stopwatch, Alarms and Clocks. Countdowns tick only
/// while the tile is on screen (the expanded panel).
struct TimeTile: View {
    @Bindable var widget: TimeWidget
    @Environment(\.inPanelTool) private var inTool

    var body: some View {
        let content = VStack(alignment: .leading, spacing: inTool ? Space.m : 6) {
            CapsuleSegments(selection: $widget.section,
                            options: TimeWidget.Section.allCases.map { ($0, $0.rawValue) },
                            label: "Time", size: inTool ? TypeScale.body.size : TypeScale.caption.size)
            switch widget.section {
            case .timers: TimersSection(widget: widget)
            case .stopwatch: StopwatchSection(widget: widget)
            case .alarms: AlarmsSection(widget: widget)
            case .clocks: ClocksSection(widget: widget)
            }
        }
        if inTool {
            // Full-panel: no card, body-size text in a readable column; an empty section's
            // state is centred in the room below the picker.
            content
                .font(DS.font(TypeScale.body))
                .frame(maxWidth: ToolPage<EmptyView>.column, maxHeight: .infinity, alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            content
                .font(.system(size: 11))
                .padding(6)
                .panelFill()
        }
    }
}

private struct IconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}

/// A section with nothing in it: one quiet line on the tile; full-panel, the symbol, a
/// title and what to do, centred in the room under the picker.
private struct TimeEmpty: View {
    let systemImage: String
    let title: String
    let detail: String
    let line: String
    @Environment(\.inPanelTool) private var inTool

    var body: some View {
        if inTool {
            ToolEmptyState(systemImage: systemImage, title: title, detail: detail)
        } else {
            Text(verbatim: line).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Timers

private struct TimersSection: View {
    let widget: TimeWidget
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("10m, 1h30, 25:00 or pomodoro", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .onChange(of: text) { invalid = false }
                    .accessibilityLabel("New timer duration")
                Button("Start", action: add)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || widget.timersFull)
                Button("Pomodoro") { widget.startPomodoro() }
                    .disabled(widget.timersFull)
                    .help("25 minutes, then a 5-minute break")
            }
            .controlSize(.small)
            if invalid {
                Text(widget.timersFull ? "Up to \(TimeStore.maxTimers) timers." : "Try 10, 10m, 1h30, 90s or 25:00 (up to 24 h).")
                    .foregroundStyle(.orange)
            }
            if widget.state.timers.isEmpty {
                TimeEmpty(systemImage: "timer", title: "No timers",
                          detail: "Type a duration like 10m or 1h30 and press Start.", line: "No timers.")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 2) {
                        ForEach(widget.state.timers) { timer in row(timer, now: ctx.date) }
                    }
                }
            }
        }
    }

    private func add() {
        if !widget.addTimer(text) { invalid = true } else { text = "" }
    }

    private func row(_ timer: CountdownTimer, now: Date) -> some View {
        let done = timer.isFinished(at: now)
        let name = timer.label.isEmpty ? "Timer" : timer.label
        return HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "timer")
                .foregroundStyle(done ? DS.dynamicColor(.working) : Color.secondary)
                .accessibilityHidden(true)
            Text(verbatim: name).lineLimit(1)
            Spacer(minLength: 4)
            Text(done ? "Done" : TodayFormat.clock(timer.remaining(at: now)))
                .monospacedDigit()
                .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
            IconButton(symbol: done ? "arrow.clockwise" : timer.phase == .running ? "pause.fill" : "play.fill",
                       label: done ? "Restart \(name)" : timer.phase == .running ? "Pause \(name)" : "Start \(name)") {
                widget.toggleTimer(timer.id)
            }
            if timer.phase != .idle, !done {
                IconButton(symbol: "stop.fill", label: "Reset \(name)") { widget.resetTimer(timer.id) }
            }
            IconButton(symbol: "xmark", label: "Remove \(name)") { widget.removeTimer(timer.id) }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Stopwatch

private struct StopwatchSection: View {
    let widget: TimeWidget

    var body: some View {
        let sw = widget.state.stopwatch
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TimelineView(.periodic(from: .now, by: sw.isRunning ? 0.1 : 3600)) { ctx in
                    Text(Stopwatch.format(sw.elapsed(at: ctx.date)))
                        .font(.system(size: TypeScale.maximum, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Button(sw.isRunning ? "Lap" : "Reset") { widget.lapOrResetStopwatch() }
                    .disabled(!sw.isRunning && sw.elapsed(at: Date()) == 0)
                Button(sw.isRunning ? "Stop" : "Start") { widget.toggleStopwatch() }
                    .buttonStyle(.borderedProminent)
                    .tint(sw.isRunning ? .red : .green)
            }
            .controlSize(.small)
            if sw.laps.count >= Stopwatch.maxLaps {
                Text("Up to \(Stopwatch.maxLaps) laps.").foregroundStyle(.tertiary)
            }
            ForEach(Array(sw.laps.enumerated().reversed().prefix(5)), id: \.offset) { index, lap in
                HStack {
                    Text("Lap \(index + 1)").foregroundStyle(.secondary)
                    Spacer()
                    Text(Stopwatch.format(lap)).monospacedDigit()
                }
            }
        }
    }
}

// MARK: - Alarms

private struct AlarmsSection: View {
    let widget: TimeWidget
    @State private var time = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                DatePicker("Alarm time", selection: $time, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                TextField("Label", text: $label)
                    .textFieldStyle(.roundedBorder)
                Button("Add") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    if widget.addAlarm(hour: c.hour ?? 7, minute: c.minute ?? 0, label: label) { label = "" }
                }
                .disabled(widget.alarmsFull)
            }
            .controlSize(.small)
            if widget.state.alarms.isEmpty {
                TimeEmpty(systemImage: "alarm", title: "No alarms",
                          detail: "Pick a time, add a label if you like, then Add.", line: "No alarms.")
            }
            ForEach(widget.state.alarms) { alarm in AlarmRow(widget: widget, alarm: alarm) }
        }
    }
}

private struct AlarmRow: View {
    let widget: TimeWidget
    let alarm: Alarm

    var body: some View {
        let time = TimeWidget.timeText(hour: alarm.hour, minute: alarm.minute)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(verbatim: time)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(alarm.enabled ? .primary : .secondary)
                Text(verbatim: alarm.label.isEmpty ? (alarm.isOnce ? "Once" : "Repeats") : alarm.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if alarm.snoozedUntil != nil {
                    Image(systemName: "zzz").foregroundStyle(.secondary).accessibilityLabel("Snoozed")
                }
                Spacer(minLength: 4)
                Toggle(isOn: Binding(get: { alarm.enabled }, set: { widget.setAlarmEnabled(alarm.id, $0) })) {
                    Text("Alarm at \(time)")
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                IconButton(symbol: "xmark", label: "Remove alarm at \(time)") { widget.removeAlarm(alarm.id) }
            }
            WeekdayChips(selected: alarm.weekdays) { widget.toggleWeekday(alarm.id, $0) }
        }
        .padding(.vertical, 2)
    }
}

/// S M T W T F S in the user's week order; none selected = once.
private struct WeekdayChips: View {
    let selected: Set<Int>
    let toggle: (Int) -> Void

    var body: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortWeekdaySymbols
        let names = cal.weekdaySymbols
        let days = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 3) {
            ForEach(days, id: \.self) { day in
                let on = selected.contains(day)
                Button { toggle(day) } label: {
                    Text(verbatim: symbols[day - 1])
                        .font(DS.font(TypeScale.caption).weight(.semibold))
                        .frame(width: 18, height: 16)
                        .foregroundStyle(on ? DS.primary : DS.secondary)
                        .background(on ? DS.ink(0.18) : DS.fill,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(names[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

// MARK: - Clocks

private struct ClocksSection: View {
    let widget: TimeWidget
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Add a city or time zone", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .disabled(widget.clocksFull)
            let matches = WorldClock.search(query, limit: 4)
            if !matches.isEmpty {
                HStack(spacing: 4) {
                    ForEach(matches, id: \.self) { tz in
                        Button(WorldClock.city(tz)) {
                            if widget.addClock(tz) { query = "" }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(tz)
                    }
                }
            }
            if widget.state.clocks.isEmpty {
                TimeEmpty(systemImage: "globe", title: "No clocks",
                          detail: "Search for a city or time zone to add a clock.", line: "No clocks.")
            } else {
                TimelineView(.everyMinute) { ctx in
                    VStack(spacing: 2) {
                        ForEach(widget.state.clocks) { clock in row(clock, now: ctx.date) }
                    }
                }
            }
        }
    }

    private func row(_ clock: WorldClock, now: Date) -> some View {
        let d = clock.display(at: now, relativeTo: .autoupdatingCurrent)
        return HStack(spacing: 6) {
            Image(systemName: d.isNight ? "moon.stars.fill" : "sun.max.fill")
                .foregroundStyle(d.isNight ? Color.indigo : .yellow)
                .accessibilityLabel(d.isNight ? "Night" : "Day")
            Text(verbatim: clock.label).lineLimit(1)
            Spacer(minLength: 4)
            if d.dayOffset != 0 {
                Text(WorldClock.dayOffsetText(d.dayOffset)).foregroundStyle(.secondary)
            }
            Text(verbatim: d.time).monospacedDigit()
            IconButton(symbol: "xmark", label: "Remove \(clock.label)") { widget.removeClock(clock.id) }
        }
    }
}
