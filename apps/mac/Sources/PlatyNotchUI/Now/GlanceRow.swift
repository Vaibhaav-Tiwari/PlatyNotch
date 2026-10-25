import PlatyNotchKit
import SwiftUI

/// One glance in the row: a widget's or the app's own usage glance.
struct GlanceEntry: Identifiable {
    let id: String
    let view: AnyView
}

/// Now's glance row (spec 6.4): up to four equal chips, 64 pt, each a card; a tap opens
/// the chip's tool (the usage chip opens Agents). A chip whose glance has nothing to show
/// is left out without a gap (`GlanceSlots.shown`).
struct GlanceRow: View {
    let entries: [GlanceEntry]
    let onOpen: (String) -> Void

    var body: some View {
        HStack(spacing: NowMetrics.gap) {
            ForEach(entries) { entry in
                Button { onOpen(entry.id) } label: {
                    entry.view
                        .padding(.horizontal, Space.m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .dsCard()
                        .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(width: Self.chipWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: NowMetrics.glance)
    }

    /// Four chips and three gaps across the panel's content width.
    static var chipWidth: CGFloat {
        let content: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelMargin
        let slots: CGFloat = CGFloat(GlanceSlots.limit)
        return (content - (slots - 1) * NowMetrics.gap) / slots
    }
}

/// The usage glance (`GlanceSlots.usageID`): Claude's 5-hour window, else Codex's.
struct UsageGlance: View {
    let usage: Usage

    var body: some View {
        if let (label, used) = Self.reading(usage) {
            GlanceChip(systemImage: "gauge.with.dots.needle.67percent", value: PanelFormat.usagePercent(used),
                       label: label, tint: used >= 90 ? DS.dynamicColor(.error) : nil)
        }
    }

    /// ("Claude 5 h", 62) or nil without limits.
    static func reading(_ usage: Usage) -> (String, Double)? {
        if let w = usage.claude?.fiveHour { return ("Claude 5 h", w.usedPercent) }
        if let w = usage.claude?.weekly { return ("Claude week", w.usedPercent) }
        if let w = usage.codex?.fiveHour { return ("Codex 5 h", w.usedPercent) }
        if let w = usage.codex?.weekly { return ("Codex week", w.usedPercent) }
        return nil
    }
}
