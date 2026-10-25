import PlatyNotchKit
import SwiftUI

/// The Agents header's usage (spec 6.5; user change: usage chips): one compact chip per
/// provider (Claude, Codex) with its icon, the percent in bold, the window and a thin bar
/// in the state palette. While Claude's limits are unavailable, a quiet placeholder chip
/// carries `hint` as its tooltip only (no permanent hint row).
struct UsageRings: View {
    let usage: Usage
    /// `PanelFormat.claudeLimitsHint`; kept only while limits are unavailable.
    let hint: String?

    init(usage: Usage, hint: String?) {
        self.usage = usage
        let readings = UsageReading.chips(usage)
        self.hint = readings.contains { $0.brand.key == "claude" } ? nil : hint
    }

    /// The chips' visible text (tests): "62%", "5 h" per chip, "Limits –" while waiting.
    var visibleTexts: [String] {
        var out: [String] = []
        for r in UsageReading.chips(usage) { out += [PanelFormat.usagePercent(r.usedPercent), r.window] }
        if hint != nil { out.append(UsageChip.unavailableText) }
        return out
    }

    var body: some View {
        let readings = UsageReading.chips(usage)
        HStack(spacing: Space.s) {
            ForEach(readings, id: \.provider) { UsageChip(reading: $0) }
            if let hint {
                UsageChip.unavailable(hint: hint)
            }
        }
    }
}

/// One provider's usage: icon, "62%", "5 h" and a bar coloured by `UsageLevel.tone`.
struct UsageChip: View {
    static let width: CGFloat = 112
    let reading: UsageReading

    var body: some View {
        let tone: StateTone = reading.level.tone
        let fraction: CGFloat = CGFloat(PanelFormat.usageFraction(reading.usedPercent))
        HStack(spacing: 6) {
            AgentBadge(brand: reading.brand, tone: nil, size: 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(verbatim: PanelFormat.usagePercent(reading.usedPercent))
                        .font(.system(size: TypeScale.headline.size, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                    Text(verbatim: reading.window)
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.card)
                        Capsule().fill(DS.dynamicColor(tone)).frame(width: g.size.width * fraction)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .frame(width: Self.width, alignment: .leading)
        .dsCard()
        .help("\(reading.provider) usage: \(reading.detail)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reading.provider) usage, \(PanelFormat.usagePercent(reading.usedPercent)) of the \(reading.window) limit")
        .accessibilityValue(reading.detail)
    }

    static let unavailableText = "Limits –"

    /// Claude with no limits yet: a dash, and the reason as the tooltip only.
    static func unavailable(hint: String) -> some View {
        HStack(spacing: 6) {
            AgentBadge(brand: AgentBrand(agent: "claude-code"), tone: nil, size: 20)
                .opacity(0.6)
            Text(verbatim: unavailableText)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 5)
        .frame(width: width, alignment: .leading)
        .dsCard()
        .help(hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Claude limits not available yet")
        .accessibilityHint(hint)
    }
}
