import PlatyNotchKit
import SwiftUI

/// Now's quiet line: "Open loops (2) · Tasks (3)", each a link into its tool. Hidden when
/// there is nothing to count (`QuietLine`).
struct QuietLineView: View {
    let items: [QuietLineItem]
    let onOpen: (String) -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 {
                    Text(verbatim: "·").foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                Button { onOpen(item.id) } label: {
                    Text(verbatim: item.text).lineLimit(1)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Open \(item.text)")
            }
            Spacer(minLength: 0)
        }
        .font(DS.font(TypeScale.caption))
        .foregroundStyle(.secondary)
        .frame(height: NowMetrics.quietLine)
    }
}
