import PlatyNotchKit
import SwiftUI

/// One rate-limit window: label, fill, percent and reset time.
struct UsageBar: View {
    let label: String
    let window: PlatyNotchKit.Window
    let now: Date

    var body: some View {
        let fraction = PanelFormat.usageFraction(window.usedPercent)
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.card)
                    Capsule()
                        .fill(Theme.color(UsageLevel(usedPercent: window.usedPercent)))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 5)
            Text(PanelFormat.usagePercent(window.usedPercent))
                .font(.system(size: 10))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            if let reset = PanelFormat.resetCountdown(resetsAt: window.resetsAt, now: now) {
                Text(reset)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) usage")
        .accessibilityValue([PanelFormat.usagePercent(window.usedPercent),
                             PanelFormat.resetCountdown(resetsAt: window.resetsAt, now: now)]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// Claude and Codex usage, 5-hour and weekly windows; providers without data are left out.
struct UsageSection: View {
    let usage: Usage

    var body: some View {
        let providers = [("Claude", usage.claude), ("Codex", usage.codex)]
            .compactMap { name, limits in limits.map { (name, $0) } }
            .filter { $0.1.fiveHour != nil || $0.1.weekly != nil }
        if !providers.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(providers, id: \.0) { provider in
                        let (name, limits) = provider
                        Text(name)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if let w = limits.fiveHour { UsageBar(label: "5 h", window: w, now: ctx.date) }
                        if let w = limits.weekly { UsageBar(label: "Week", window: w, now: ctx.date) }
                    }
                }
            }
        }
    }
}
