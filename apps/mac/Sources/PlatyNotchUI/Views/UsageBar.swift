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
                .font(DS.font(TypeScale.caption).weight(.medium))
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
                .font(DS.font(TypeScale.caption))
                .monospacedDigit()
                .frame(width: 32, alignment: .trailing)
            if let reset = PanelFormat.resetCountdown(resetsAt: window.resetsAt, now: now) {
                Text(reset)
                    .font(DS.font(TypeScale.caption))
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

    /// Named providers with at least one window (typed steps: the chained tuple closures
    /// were the slowest expression to type-check in the app).
    static func providers(_ usage: Usage) -> [(String, Limits)] {
        var out: [(String, Limits)] = []
        for (name, limits) in [("Claude", usage.claude), ("Codex", usage.codex)] {
            guard let limits, limits.fiveHour != nil || limits.weekly != nil else { continue }
            out.append((name, limits))
        }
        return out
    }

    var body: some View {
        let providers = Self.providers(usage)
        if !providers.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(providers, id: \.0) { provider in
                        let (name, limits) = provider
                        Text(name)
                            .font(DS.font(TypeScale.caption).weight(.semibold))
                            .foregroundStyle(.secondary)
                        if let w = limits.fiveHour { UsageBar(label: "5 h", window: w, now: ctx.date) }
                        if let w = limits.weekly { UsageBar(label: "Week", window: w, now: ctx.date) }
                    }
                }
            }
        }
    }
}
