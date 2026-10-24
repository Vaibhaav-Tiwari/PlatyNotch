import PlatyNotchKit
import SwiftUI

/// The Today tile: battery (laptops only) and keep-awake, then the opt-in rows.
struct SystemTile: View {
    let widget: SystemWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let b = widget.battery {
                BatteryRow(state: b)
            }
            KeepAwakeRow(widget: widget)
        }
    }
}

struct BatteryRow: View {
    let state: BatteryState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbolName)
                .foregroundStyle(state.isLow ? Theme.tint(.critical) : state.pluggedIn ? Theme.tint(.accent) : .primary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(verbatim: "\(state.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Text(state.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keep awake: a menu of durations; while on, the time left (ticking only while the tile
/// is on screen) and Stop.
struct KeepAwakeRow: View {
    let widget: SystemWidget

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: widget.keepAwake.session == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
                .foregroundStyle(widget.keepAwake.session == nil ? Color.secondary : Theme.tint(.accent))
                .frame(width: 22)
                .accessibilityHidden(true)
            if let s = widget.keepAwake.session {
                if let until = s.until {
                    TimelineView(.periodic(from: s.startedAt, by: 1)) { ctx in
                        Text("Awake · \(TodayFormat.clock(until.timeIntervalSince(ctx.date))) left")
                            .font(.system(size: 12)).monospacedDigit()
                    }
                } else {
                    Text("Awake until turned off").font(.system(size: 12))
                }
                Spacer(minLength: 4)
                durationMenu(title: "Change")
                Button("Stop") { widget.stopKeepAwake() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Text("Keep awake").font(.system(size: 12))
                Spacer(minLength: 4)
                durationMenu(title: "Start")
            }
        }
        if let error = widget.keepAwake.lastError {
            Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func durationMenu(title: String) -> some View {
        Menu(title) {
            ForEach(KeepAwakeDuration.allCases, id: \.self) { d in
                Button(d.label) { widget.startKeepAwake(d) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 11))
        .accessibilityLabel(title == "Start" ? "Keep awake for" : "Change keep-awake time")
    }
}

/// The plug-in / unplug peek below the notch (`PanelLayout.widgetPeekHeight`).
struct PowerPeekView: View {
    let peek: SystemWidget.PowerPeek

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peek.change == .pluggedIn ? "bolt.fill" : peek.state.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(peek.change == .pluggedIn ? Theme.tint(.accent)
                                 : peek.state.isLow ? Theme.tint(.critical) : .primary)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(peek.change == .pluggedIn ? "Plugged in" : "On battery")
                    .font(.system(size: 13, weight: .semibold))
                Text(peek.state.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(peek.state.percent)%")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Widgets › System.
struct SystemSettings: View {
    let widget: SystemWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Battery: a peek with the percent when you plug in or unplug, and the pill shows low battery "
                 + "(10% or less) and charging. Keep awake: stops the display sleeping for the time you pick; "
                 + "it ends when the time is up, when you turn this widget off, or when you quit. "
                 + "Neither needs a permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
