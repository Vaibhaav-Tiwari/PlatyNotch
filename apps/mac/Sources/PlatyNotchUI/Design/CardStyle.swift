import PlatyNotchKit
import SwiftUI

/// The one elevated card style (spec 7.1): the surface one step up (`cardOverlay` of white
/// over dark, of black over light) with a 1 px inner keyline (`keylineAlpha`, or a tint).
/// Used for the hero, glance chips, tiles and approval cards; plain list rows get none.
private struct DSCard: ViewModifier {
    let radius: CGFloat
    let keyline: Color?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let ink: Color = scheme == .light ? .black : .white
        let line: Color = keyline ?? ink.opacity(PanelPalette.keylineAlpha)
        let width: CGFloat = 1 / max(displayScale, 1)
        content
            .background(ink.opacity(PanelPalette.cardOverlay), in: shape)
            .overlay(shape.strokeBorder(line, lineWidth: width))
    }
}

extension View {
    /// A card: surface +1 step, 1 px inner keyline, a radius from the scale.
    func dsCard(radius: CGFloat = Radius.card, keyline: Color? = nil) -> some View {
        modifier(DSCard(radius: radius, keyline: keyline))
    }
}
