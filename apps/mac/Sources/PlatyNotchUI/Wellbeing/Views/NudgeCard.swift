import PlatyNotchKit
import SwiftUI

/// What each nudge says.
enum NudgeText {
    static func title(_ kind: NudgeKind) -> String {
        switch kind {
        case .water: "Time for some water"
        case .stand: "Stand up and stretch"
        case .eyes: "Look 20 feet away for 20 seconds"
        }
    }

    static func symbol(_ kind: NudgeKind) -> String {
        switch kind {
        case .water: "drop.fill"
        case .stand: "figure.stand"
        case .eyes: "eye"
        }
    }

    static func name(_ kind: NudgeKind) -> String {
        switch kind {
        case .water: "Water"
        case .stand: "Stand"
        case .eyes: "Eye break"
        }
    }

    static func glasses(_ count: Int, goal: Int) -> String { "\(count) / \(goal) glasses today" }
}

/// The nudge below the notch (`PanelLayout.widgetPeekHeight`). The panel never takes
/// keyboard focus for it; its buttons work on the first click (the hosting view accepts
/// the first mouse). The eyes card has a 20-second countdown ring.
struct NudgeCard: View {
    let widget: WellbeingWidget
    let nudge: WellbeingWidget.Nudge

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if nudge.kind == .eyes {
                    TimelineView(.periodic(from: nudge.shownAt, by: 1)) { ctx in
                        EyeBreakRing(start: nudge.shownAt, now: ctx.date)
                    }
                } else {
                    Image(systemName: NudgeText.symbol(nudge.kind))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.tint(.accent))
                        .frame(width: 34, height: 34)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(NudgeText.title(nudge.kind))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if nudge.kind == .water {
                        Text(NudgeText.glasses(widget.glassesToday(), goal: widget.settings.dailyWaterGoal))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Snooze 10 min") { widget.snooze(nudge.kind) }
                    .controlSize(.small)
                if nudge.kind == .water {
                    Button("+1 glass") { widget.addGlass() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button("Done") { widget.done(nudge.kind) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Counts down the 20 seconds of an eye break.
struct EyeBreakRing: View {
    let start: Date
    let now: Date
    var size: CGFloat = 34

    var body: some View {
        let total = NudgeScheduler.eyesBreak
        let elapsed = min(max(now.timeIntervalSince(start), 0), total)
        let left = Int((total - elapsed).rounded(.up))
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: 1 - elapsed / total)
                .stroke(Theme.tint(.accent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(left)").font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(left) seconds left")
    }
}

/// The Today tile: each nudge's interval and next time, and today's water.
struct WellbeingTile: View {
    let widget: WellbeingWidget

    var body: some View {
        let s = widget.settings
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: NudgeText.symbol(.water)).foregroundStyle(Theme.tint(.accent)).frame(width: 18)
                    .accessibilityHidden(true)
                Text(NudgeText.glasses(widget.glassesToday(), goal: s.dailyWaterGoal)).font(.system(size: 12))
                Spacer(minLength: 4)
                Button("+1 glass") { widget.addGlass() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            ForEach([NudgeKind.eyes, .stand, .water], id: \.self) { kind in
                HStack(spacing: 8) {
                    Image(systemName: NudgeText.symbol(kind)).foregroundStyle(.secondary).frame(width: 18)
                        .accessibilityHidden(true)
                    Text(NudgeText.name(kind)).font(.system(size: 11))
                    Spacer(minLength: 4)
                    Text(status(kind)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let quiet = quietNote() {
                Text(quiet).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private func status(_ kind: NudgeKind) -> String {
        let s = widget.settings
        guard s.interval(kind) != nil else { return "Off" }
        let every = "Every \(s.minutes(kind)) min"
        guard let due = NudgeScheduler.dueDate(kind, s, lastDone: widget.progress.lastDone,
                                               snoozedUntil: widget.progress.snoozedUntil) else { return every }
        return every + " · next " + due.formatted(date: .omitted, time: .shortened)
    }

    private func quietNote() -> String? {
        let s = widget.settings
        let now = Date()
        guard NudgeScheduler.isQuiet(s, at: now, calendar: widget.calendar),
              let end = NudgeScheduler.quietEnd(after: now, s, calendar: widget.calendar) else { return nil }
        return "Quiet hours until " + end.formatted(date: .omitted, time: .shortened)
    }
}

/// Settings › Widgets › Wellbeing: intervals (0 = off), quiet hours, the daily water goal.
struct WellbeingSettings: View {
    let widget: WellbeingWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([NudgeKind.water, .stand, .eyes], id: \.self) { kind in
                Stepper(value: minutes(kind), in: 0...NudgeSettings.maxMinutes, step: 5) {
                    HStack {
                        Text(NudgeText.name(kind))
                        Spacer()
                        Text(widget.settings.minutes(kind) == 0 ? "Off" : "Every \(widget.settings.minutes(kind)) min")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Text("Quiet hours")
                Spacer()
                Picker("From", selection: hour(\.quietStart)) { hours }
                    .labelsHidden().frame(width: 90)
                Text("to")
                Picker("To", selection: hour(\.quietEnd)) { hours }
                    .labelsHidden().frame(width: 90)
            }
            Stepper(value: goal, in: 1...30) {
                HStack {
                    Text("Daily water goal")
                    Spacer()
                    Text("\(widget.settings.dailyWaterGoal) glasses").foregroundStyle(.secondary)
                }
            }
            Text("Set an interval to 0 to turn that nudge off. Same start and end turns quiet hours off. "
                 + "Nudges wait during a focus session, a meeting (with the Meetings widget and calendar access), "
                 + "full screen and quiet hours, and 5 minutes away from the keyboard counts as a break. "
                 + "No permission needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var hours: some View {
        ForEach(0..<24, id: \.self) { h in
            Text(Self.hourLabel(h)).tag(h)
        }
    }

    static func hourLabel(_ h: Int) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: h)) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func minutes(_ kind: NudgeKind) -> Binding<Int> {
        Binding(get: { widget.settings.minutes(kind) },
                set: { v in var s = widget.settings; s.setMinutes(v, for: kind); widget.update(s) })
    }

    private func hour(_ key: WritableKeyPath<NudgeSettings, Int>) -> Binding<Int> {
        Binding(get: { widget.settings[keyPath: key] },
                set: { v in var s = widget.settings; s[keyPath: key] = v; widget.update(s) })
    }

    private var goal: Binding<Int> {
        Binding(get: { widget.settings.dailyWaterGoal },
                set: { v in var s = widget.settings; s.dailyWaterGoal = v; widget.update(s) })
    }
}
