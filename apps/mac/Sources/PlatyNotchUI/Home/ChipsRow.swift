import PlatyNotchKit
import SwiftUI

/// Home's live chips (spec 2.2): focus, running timers, the shelf; the row is absent when
/// nothing is live. A click opens that feature inside the panel.
struct ChipsRow: View {
    let chips: [LiveChip]
    let overflow: Int
    let onOpen: (String) -> Void

    /// The tool a chip opens.
    static func tool(for chip: LiveChip) -> String {
        switch chip.kind {
        case .focus: FocusWidget.widgetID
        case .timer: TimeWidget.widgetID
        case .shelf: ShelfWidget.widgetID
        }
    }

    static func symbol(for chip: LiveChip) -> String? {
        switch chip.kind {
        case .shelf: "tray"
        default: nil
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button { onOpen(Self.tool(for: chip)) } label: {
                    HStack(spacing: 6) {
                        if let tone = chip.tone {
                            Circle().fill(DS.dynamicColor(tone)).frame(width: 7, height: 7)
                        }
                        if let symbol = Self.symbol(for: chip) {
                            Image(systemName: symbol).font(.system(size: 11))
                        }
                        Text(verbatim: chip.text)
                            .font(.system(size: 12).monospacedDigit())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(chip.text)
            }
            if overflow > 0 {
                Text(verbatim: "+\(overflow)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(overflow) more")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
