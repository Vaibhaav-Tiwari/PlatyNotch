import PlatyNotchKit
import SwiftUI

/// The content of one glance chip in Now (spec 6.4): an icon at the row size, the value in
/// the rounded headline and a short caption label ("10:30" / "Design"). The chip's card,
/// size and tap belong to `GlanceRow`; widgets return this from `glanceView()`.
struct GlanceChip: View {
    let systemImage: String
    let value: String
    let label: String
    /// A state or accent colour for the icon (never the only carrier: the label says it).
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DS.icon(systemImage, size: IconSize.row)
                    .foregroundStyle(tint ?? .secondary)
                    .accessibilityHidden(true)
                Text(verbatim: value)
                    .font(DS.font(TypeScale.headline, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Text(verbatim: label)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}
