import PlatyNotchKit
import SwiftUI

/// The open/close morph's shared state (spec 9): the panel's namespace and which live item's
/// glyph morphs (`Morph.matches`); nil in the environment when motion is reduced, so
/// nothing morphs and mode changes only cross-fade.
struct MorphContext: Equatable {
    let namespace: Namespace.ID
    /// The live item shown both in the pill's trailing side and as the hero, if any.
    let liveID: String?
}

extension EnvironmentValues {
    @Entry var morph: MorphContext? = nil
    /// The live item Now's hero shows (its glyph morphs when it is `MorphContext.liveID`).
    @Entry var heroItemID: String? = nil
    /// The open panel's chrome (tab bar, Now's rows, the hero's text): 0 while the panel
    /// is still growing out of the pill, 1 once it has settled (`ChromeSettle`).
    @Entry var chromeOpacity: Double = 1
}

/// Content that grows out of the pill: laid out at its final size and clipped by the
/// growing panel, its chrome fades in only after the size has mostly settled
/// (`chromeDelay`, then `chromeFade`), so nothing half-laid-out shows mid-spring; the
/// morphing views (Platy, the live glyph) are not chrome and fly at once. Under reduced
/// motion (no morph) the chrome shows at once and the panel cross-fades as before.
struct ChromeSettle<Content: View>: View {
    static var chromeDelay: Double { 0.15 }
    static var chromeFade: Double { 0.15 }
    /// How fast the content goes when the panel closes.
    static var removalFade: Double { 0.08 }

    @ViewBuilder let content: Content
    @Environment(\.morph) private var morph
    @State private var settled = false

    var body: some View {
        content
            .environment(\.chromeOpacity, settled || morph == nil ? 1 : 0)
            .onAppear {
                guard morph != nil else { settled = true; return }
                withAnimation(.easeOut(duration: Self.chromeFade).delay(Self.chromeDelay)) { settled = true }
            }
    }

    /// Appears at once (its chrome fades in on its own), goes quickly.
    static var transition: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: removalFade)))
    }
}

extension View {
    /// Matched geometry for `id` in the panel's morph namespace; nothing without a
    /// namespace (reduced motion, renders) or without an id.
    func morph(_ id: String?) -> some View {
        modifier(MorphGeometry(id: id))
    }

    /// Panel chrome: hidden while the panel grows out of the pill (`ChromeSettle`).
    func panelChrome() -> some View {
        modifier(PanelChrome())
    }
}

private struct MorphGeometry: ViewModifier {
    let id: String?
    @Environment(\.morph) private var morph

    func body(content: Content) -> some View {
        if let id, let morph {
            // Above its neighbours, so a glyph in flight is never drawn under them.
            content.matchedGeometryEffect(id: id, in: morph.namespace).zIndex(1)
        } else {
            content
        }
    }
}

private struct PanelChrome: ViewModifier {
    @Environment(\.chromeOpacity) private var opacity

    func body(content: Content) -> some View {
        content.opacity(opacity)
    }
}
