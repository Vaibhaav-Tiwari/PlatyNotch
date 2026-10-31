import PlatyNotchKit
import SwiftUI

/// The Timer tool's state, shared by its header chips and its body (one per app): the
/// mode, the chosen length per mode, the custom field, and the timer this tool started.
@MainActor @Observable
final class TimerToolModel {
    static let shared = TimerToolModel()

    var mode: TimerMode = .timer
    var timerSelection: TimeInterval = TimerPresets.timerDefault
    var focusSelection: TimeInterval = TimerPresets.focusDefault
    /// The "+ custom" field: shown, its text, and why it was refused.
    var customOpen = false
    var customText = ""
    var customMessage: String?
    /// The timer last started here: the big number follows it while it runs.
    var activeTimer: UUID?

    static let customHint = "Try 10m or 1h 5m"

    var selection: TimeInterval {
        get { mode == .focus ? focusSelection : timerSelection }
        set { if mode == .focus { focusSelection = newValue } else { timerSelection = newValue } }
    }

    var presets: [TimeInterval] { mode == .focus ? TimerPresets.focus : TimerPresets.timer }

    /// The mode the tool opens in: the one asked for, else Focus while a session runs, else
    /// Stopwatch while it runs, else Timer.
    func open(initial: TimerMode?, focusRunning: Bool, stopwatchRunning: Bool = false) {
        mode = initial ?? (focusRunning ? .focus : (stopwatchRunning ? .stopwatch : .timer))
        customOpen = false
        customMessage = nil
    }

    /// The custom field's text, read by `DurationParser`: a length selects it, anything else
    /// says how to type one (nothing starts).
    @discardableResult
    func applyCustom() -> Bool {
        guard let t = DurationParser.parse(customText) else {
            customMessage = Self.customHint
            return false
        }
        selection = t
        customMessage = nil
        customOpen = false
        customText = ""
        return true
    }

    /// Start in Timer mode: one timer of the chosen length, unlabelled.
    @discardableResult
    func startTimer(_ starter: TimerStarter?, timers: () -> [CountdownTimer]) -> Bool {
        guard let starter, starter.startTimer(duration: timerSelection, label: nil) else { return false }
        activeTimer = timers().last?.id
        return true
    }
}

/// The Timer tool (Island spec 4, wireframe C): the value at 54 pt SF Pro Rounded, one-tap
/// presets, and a 170 pt column with Start (Pause and Stop while running) and the running
/// timers, the soonest with an amber dot. Focus counts a focus session; Stopwatch has
/// Start / Lap / Reset and its laps in the column. The modes are chips in the header.
struct TimerTool: View {
    let time: TimeWidget?
    let focus: FocusModel?
    var model: TimerToolModel = .shared
    var fixedNow: Date?
    /// The mode asked for by the route (`timer.focus`), applied when the tool appears.
    let initial: TimerMode?

    init(time: TimeWidget?, focus: FocusModel?, initial: TimerMode? = nil, model: TimerToolModel = .shared,
         fixedNow: Date? = nil) {
        self.time = time
        self.focus = focus
        self.model = model
        self.fixedNow = fixedNow
        self.initial = initial
    }

    /// Opening the tool: the asked-for mode, or Focus while a session runs.
    func appeared() {
        model.open(initial: initial, focusRunning: focus?.timer?.isRunning(at: fixedNow ?? Date()) ?? false,
                   stopwatchRunning: time?.state.stopwatch.isRunning ?? false)
    }

    /// The big number: what runs, else the chosen length.
    static func bigText(mode: TimerMode, selection: TimeInterval, running: TimeInterval?) -> String {
        DockState.clock(running ?? selection)
    }

    /// The number's type (Island spec 9: only the Timer tool uses it).
    static let numberFont: Font = DS.font(TypeScale.timer)

    /// The header's mode chips.
    static func modeTitles() -> [String] { TimerMode.allCases.map(\.title) }

    /// Something counts (a timer, focus or the stopwatch): only then does the tool tick.
    private func anythingRuns(_ now: Date) -> Bool {
        (time?.state.timers.contains { $0.isRunning(at: now) } ?? false)
            || (focus?.timer?.isRunning(at: now) ?? false)
            || (time?.state.stopwatch.isRunning ?? false)
    }

    /// The right column's list in every mode (laps in Stopwatch): the running timers, the
    /// soonest first, or one quiet line when none runs.
    static func columnRows(mode: TimerMode, timers: [CountdownTimer], laps: [TimeInterval], now: Date) -> [String] {
        if mode == .stopwatch, !laps.isEmpty {
            return laps.enumerated().reversed().prefix(4).map { "Lap \($0.offset + 1) · \(Stopwatch.format($0.element))" }
        }
        let rows = RunningTimers.rows(timers, now: now).prefix(4).map(\.text)
        return rows.isEmpty ? [noneRunning] : Array(rows)
    }

    static let noneRunning = "No timers running"

    /// Focus minutes for a length: rounded, at least one (a custom "30s" is a minute).
    static func focusMinutes(_ t: TimeInterval) -> Int { max(1, Int((t / 60).rounded())) }

    var body: some View {
        let now: Date = fixedNow ?? Date()
        // Idle, nothing changes each second: no tick (M2).
        TickingNow(fixed: fixedNow ?? (anythingRuns(now) ? nil : now)) { now in
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(verbatim: bigText(now: now))
                        .font(Self.numberFont.monospacedDigit())
                        .tracking(-1)
                        .foregroundStyle(DS.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityLabel(bigText(now: now))
                    if model.mode != .stopwatch { presetRow }
                    if let message = model.customMessage {
                        Text(verbatim: message).font(DS.font(TypeScale.caption)).foregroundStyle(DS.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                column(now: now)
                    .frame(width: HomeMetrics.timerColumn)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear { appeared() }
    }

    // MARK: - Values

    private func activeTimer(now: Date) -> CountdownTimer? {
        guard let id = model.activeTimer else { return nil }
        return time?.state.timers.first { $0.id == id && $0.phase != .idle && !$0.isFinished(at: now) }
    }

    private func bigText(now: Date) -> String {
        switch model.mode {
        case .timer:
            return Self.bigText(mode: .timer, selection: model.timerSelection, running: activeTimer(now: now)?.remaining(at: now))
        case .focus:
            let left: TimeInterval? = focus?.timer.flatMap { $0.phase == .idle || $0.isDone(at: now) ? nil : $0.remaining(at: now) }
            return Self.bigText(mode: .focus, selection: model.focusSelection, running: left)
        case .stopwatch:
            return DockState.clock(time?.state.stopwatch.elapsed(at: now).rounded(.down) ?? 0)
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(model.presets, id: \.self) { t in
                ModeChip(title: TimerPresets.chipTitle(t), selected: model.selection == t) {
                    model.selection = t
                    model.customOpen = false
                    model.customMessage = nil
                }
            }
            if model.customOpen {
                TextField("", text: Binding(get: { model.customText }, set: { model.customText = $0 }),
                          prompt: Text(verbatim: "1h 5m").foregroundStyle(DS.tertiary))
                    .textFieldStyle(.plain)
                    .font(DS.font(TypeScale.secondary))
                    .frame(width: 64)
                    .padding(.vertical, 5)
                    .padding(.horizontal, 10)
                    .background(DS.raised, in: Capsule())
                    .onSubmit { model.applyCustom() }
            } else {
                let custom: Bool = !model.presets.contains(model.selection)
                ModeChip(title: custom ? TimerPresets.chipTitle(model.selection) : "+ custom", selected: custom) {
                    model.customOpen = true
                }
            }
        }
    }

    // MARK: - Column

    @ViewBuilder private func column(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.mode {
            case .timer: timerButtons(now: now)
            case .focus: focusButtons(now: now)
            case .stopwatch: stopwatchButtons
            }
            list(now: now)
        }
        .frame(minHeight: 96, alignment: .top)
    }

    @ViewBuilder private func timerButtons(now: Date) -> some View {
        if let t = activeTimer(now: now) {
            HStack(spacing: 8) {
                ToolButton(title: t.phase == .running ? "Pause" : "Resume", primary: true) { time?.toggleTimer(t.id) }
                ToolButton(title: "Stop", primary: false) {
                    time?.removeTimer(t.id)
                    model.activeTimer = nil
                }
            }
        } else {
            ToolButton(title: "Start", primary: true) {
                model.startTimer(time) { time?.state.timers ?? [] }
            }
            .disabled(time == nil)
        }
    }

    @ViewBuilder private func focusButtons(now: Date) -> some View {
        if let f = focus?.timer, f.phase != .idle, !f.isDone(at: now) {
            HStack(spacing: 8) {
                ToolButton(title: f.phase == .running ? "Pause" : "Resume", primary: true) {
                    if f.phase == .running { focus?.pause() } else { focus?.resume() }
                }
                ToolButton(title: "Stop", primary: false) { focus?.stop() }
            }
        } else {
            ToolButton(title: "Start", primary: true) { focus?.start(minutes: Self.focusMinutes(model.focusSelection)) }
                .disabled(focus == nil)
        }
    }

    private var stopwatchButtons: some View {
        let running: Bool = time?.state.stopwatch.isRunning ?? false
        let started: Bool = (time?.state.stopwatch.elapsed(at: Date()) ?? 0) > 0
        return HStack(spacing: 8) {
            ToolButton(title: running ? "Stop" : "Start", primary: true) { time?.toggleStopwatch() }
            ToolButton(title: running ? "Lap" : "Reset", primary: false) { time?.lapOrResetStopwatch() }
                .disabled(!running && !started)
        }
        .disabled(time == nil)
    }

    @ViewBuilder private func list(now: Date) -> some View {
        let laps: [TimeInterval] = time?.state.stopwatch.laps ?? []
        let texts = Self.columnRows(mode: model.mode, timers: time?.state.timers ?? [], laps: laps, now: now)
        if texts == [Self.noneRunning] {
            Text(verbatim: Self.noneRunning)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(DS.tertiary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        } else {
            let lapping: Bool = model.mode == .stopwatch && !laps.isEmpty
            ForEach(Array(texts.enumerated()), id: \.offset) { i, text in
                row(dot: lapping ? nil : (i == 0 ? DS.color(.needsYou) : DS.tertiary), text: text)
            }
        }
    }

    private func row(dot: Color?, text: String) -> some View {
        HStack(spacing: 8) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(verbatim: text)
                .font(DS.font(TypeScale.secondary).monospacedDigit())
                .foregroundStyle(DS.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 4)
    }
}

/// The header's mode chips: Timer · Focus · Stopwatch (the selected one white with black text).
struct TimerModeChips: View {
    var model: TimerToolModel = .shared

    var body: some View {
        HStack(spacing: 6) {
            ForEach(TimerMode.allCases, id: \.self) { m in
                ModeChip(title: m.title, selected: model.mode == m, compact: true) {
                    model.mode = m
                    model.customOpen = false
                    model.customMessage = nil
                }
            }
        }
    }
}

/// Island's chip button: a `raised` capsule; selected, white with black text.
struct ModeChip: View {
    let title: String
    let selected: Bool
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(DS.font(TypeScale.secondary).weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.black : DS.primary)
                .padding(.vertical, compact ? 3 : 5)
                .padding(.horizontal, compact ? 10 : 12)
                .background(selected ? DS.primary : DS.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A tool's button: white with black text (primary) or `raised`, radius 10 per the wireframe
/// (on the scale: 8), 13 pt semibold, full width of its column.
struct ToolButton: View {
    let title: String
    let primary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(DS.font(TypeScale.body).weight(.semibold))
                .foregroundStyle(primary ? Color.black : DS.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(primary ? DS.primary : DS.raised,
                            in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
