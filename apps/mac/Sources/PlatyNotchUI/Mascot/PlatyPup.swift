import AppKit
import PlatyNotchKit
import SwiftUI

/// An agent pup (spec 8.3): a small Platy with a bandana in the agent's colour and, unless
/// `badge` is off, the session state as the Agents rows' `StateBadge` (one monochrome SF
/// Symbol on a 16 pt surface circle) at the bottom right. A still image, drawn once per (agent, tone, size, scale, scheme)
/// and cached; never animated.
///
/// Where pups appear (user ruling: recognisable icons first): the Agents rows keep the
/// agent's installed app icon or monogram (`AgentBadge`) as the identity; pups appear only
/// where they add warmth without costing clarity: the Agents empty state (the four known
/// agents waiting) and the gallery.
struct PlatyPupView: View {
    let agent: AgentIdentity
    let tone: StateTone
    let size: CGFloat
    var badge: Bool = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    init(agent: AgentIdentity, tone: StateTone, size: CGFloat, badge: Bool = true) {
        self.agent = agent
        self.tone = tone
        self.size = size
        self.badge = badge
    }

    var body: some View {
        Group {
            if let image = PupImages.image(agent: agent, tone: tone, size: size, scale: max(displayScale, 1),
                                           dark: scheme != .light, badge: badge) {
                Image(decorative: image, scale: max(displayScale, 1))
                    .resizable()
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The pups' still images.
@MainActor
enum PupImages {
    private struct Key: Hashable {
        let agent: AgentIdentity
        let tone: StateTone
        let size: CGFloat
        let scale: CGFloat
        let dark: Bool
        let badge: Bool
    }

    private static var cache: [Key: CGImage] = [:]

    static func image(agent: AgentIdentity, tone: StateTone, size: CGFloat, scale: CGFloat, dark: Bool,
                      badge: Bool = true) -> CGImage? {
        let key = Key(agent: agent, tone: tone, size: size, scale: scale, dark: dark, badge: badge)
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: PupCanvas(agent: agent, tone: tone, size: size, dark: dark, badge: badge))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        cache[key] = image
        return image
    }
}

/// One pup, drawn for `PupImages`.
private struct PupCanvas: View {
    let agent: AgentIdentity
    let tone: StateTone
    let size: CGFloat
    let dark: Bool
    let badge: Bool

    var body: some View {
        let bandana = Color(agent.rgb)
        PlatyCanvas(pose: .rest(.idle), size: size, bandana: bandana)
            .overlay(alignment: .bottomTrailing) {
                if badge { StateBadge(tone: tone) }
            }
            .frame(width: size, height: size)
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}
