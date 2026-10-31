import PlatyNotchKit
import SwiftUI

/// While a file drag nears the notch the Home body becomes drop targets in one dashed box
/// (spec 2.2): "Drop to keep on Shelf" and "AirDrop". Shelf off: AirDrop only.
struct DropTargetsView: View {
    enum Zone: Equatable { case shelf, airDrop }

    let shelfOn: Bool
    let airDrop: Bool
    /// Which target the pointer is over (the window's drag location).
    var hovered: Zone?

    static let shelfTitle = "Drop to keep on Shelf"
    static let airDropTitle = "AirDrop"

    static func titles(shelfOn: Bool, airDrop: Bool) -> [String] {
        var out: [String] = []
        if shelfOn { out.append(shelfTitle) }
        if airDrop { out.append(airDropTitle) }
        return out
    }

    /// The target at horizontal position `x` of a panel `width` wide: the left half keeps on
    /// the Shelf and the right half AirDrops; with one target on, it takes the whole box.
    static func zone(atX x: CGFloat, width: CGFloat, shelfOn: Bool, airDrop: Bool) -> Zone? {
        switch (shelfOn, airDrop) {
        case (true, true): return x < width / 2 ? .shelf : .airDrop
        case (true, false): return .shelf
        case (false, true): return .airDrop
        case (false, false): return nil
        }
    }

    var body: some View {
        let titles = Self.titles(shelfOn: shelfOn, airDrop: airDrop)
        HStack(spacing: HomeMetrics.columnGap) {
            ForEach(titles, id: \.self) { title in
                let zone: Zone = title == Self.airDropTitle ? .airDrop : .shelf
                VStack(spacing: 6) {
                    Image(systemName: zone == .shelf ? "tray.and.arrow.down" : "dot.radiowaves.up.forward")
                        .font(.system(size: 20, weight: .medium))
                    Text(verbatim: title).font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(hovered == zone ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: HomeMetrics.dropBoxHeight)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(hovered != nil ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.6))
        )
    }
}
