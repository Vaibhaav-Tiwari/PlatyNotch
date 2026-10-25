import PlatyNotchKit
import SwiftUI

/// The open/close morph's shared state (spec 9): the panel's namespace and which live item's
/// glyph morphs (`Morph.matches`); nil in the environment when motion is reduced, so
/// nothing morphs and mode changes only cross-fade.
struct MorphContext {
    let namespace: Namespace.ID
    /// The live item shown both in the pill's trailing side and as the hero, if any.
    let liveID: String?
}

extension EnvironmentValues {
    @Entry var morph: MorphContext? = nil
    /// The live item Now's hero shows (its glyph morphs when it is `MorphContext.liveID`).
    @Entry var heroItemID: String? = nil
}

extension View {
    /// Matched geometry for `id` in the panel's morph namespace; nothing without a
    /// namespace (reduced motion, renders) or without an id.
    func morph(_ id: String?) -> some View {
        modifier(MorphGeometry(id: id))
    }
}

private struct MorphGeometry: ViewModifier {
    let id: String?
    @Environment(\.morph) private var morph

    func body(content: Content) -> some View {
        if let id, let morph {
            content.matchedGeometryEffect(id: id, in: morph.namespace)
        } else {
            content
        }
    }
}
