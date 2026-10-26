import PlatyNotchKit
import SwiftUI

extension View {
    /// A Settings group: a soft fill and a hairline on the card radius (`Radius.card`), the
    /// one style for grouped rows in Settings (Notifications, permissions, sound, widget
    /// cards). `fill`: the fill's opacity (a hovered card is a touch stronger); `accent`: a
    /// 1.5 pt accent keyline instead of the hairline (a drop target).
    func settingsGroup(fill: Double = 0.04, accent: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        let line: Color = accent ?? Color.primary.opacity(0.06)
        let width: CGFloat = accent == nil ? 1 : 1.5
        return self
            .background(Color.primary.opacity(fill), in: shape)
            .overlay(shape.strokeBorder(line, lineWidth: width))
    }
}
