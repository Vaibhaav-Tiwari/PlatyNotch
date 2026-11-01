import AppKit
import PlatyNotchKit
import SwiftUI

/// The closed pill's lead (Island spec 7, wireframe F), split across the two ears: the first
/// part sits in the agents ear, the rest in the live ear.
/// - Music: the mini art (20 pt, radius 6), then five bars in the art's colour.
/// - Timer: Platy, then the time left (amber, 12 pt rounded semibold).
/// - Needs you: the session's app icon (18 pt; its name as text with no app), then amber
///   "Needs you".
/// Approvals, working agents and nothing live keep the pill's own ears (`draws`). Colour
/// here comes from the content only (the art); the amber words are `PillLeadText`.
struct PillLeadView: View {
    enum Part: Equatable {
        case art, bars, platy, appIcon
        /// The agent's name in place of its app icon (secondary).
        case name(String)
        /// Amber words: the time left or "Needs you".
        case text(String)
    }

    enum Side { case leading, trailing, both }

    let lead: PillLead
    let art: NSImage?
    let tint: RGB?
    let appIcon: NSImage?
    let agentName: String
    var platy: PlatyMood? = .idle
    var side: Side = .both

    static let artSize: CGFloat = 20
    static let artRadius: CGFloat = Radius.small
    static let appIconSize: CGFloat = 18
    static let timeStyle: TypeStyle = TypeScale.pillTime
    static let needsYou = "Needs you"

    /// Whether the lead replaces the ears' usual content.
    static func draws(_ lead: PillLead) -> Bool {
        switch lead {
        case .music, .timer, .needsYou: true
        case .approval, .agents, .none: false
        }
    }

    /// The words the lead shows.
    static func texts(_ lead: PillLead, agentName: String, hasAppIcon: Bool = true) -> [String] {
        parts(lead, hasArt: false, hasAppIcon: hasAppIcon, agentName: agentName).compactMap { part in
            switch part {
            case .text(let s), .name(let s): s
            default: nil
            }
        }
    }

    /// What the lead draws, in order (the first in the agents ear when there are two or more).
    static func parts(_ lead: PillLead, hasArt: Bool, hasAppIcon: Bool, agentName: String = "") -> [Part] {
        switch lead {
        case .music: hasArt ? [.art, .bars] : [.bars]
        case .timer(let remaining): [.platy, .text(remaining)]
        case .needsYou: [hasAppIcon ? .appIcon : .name(agentName), .text(needsYou)]
        case .approval, .agents, .none: []
        }
    }

    /// The bars' colour: the art's, or the glow's fallback for missing or monochrome art.
    static func barsColor(_ tint: RGB?) -> RGB { NowPlayingCard.glowColor(tint: tint) }

    var body: some View {
        let all: [Part] = Self.parts(lead, hasArt: art != nil, hasAppIcon: appIcon != nil, agentName: agentName)
        let shown: [Part] = switch side {
        case .both: all
        case .leading: all.count > 1 ? [all[0]] : []
        case .trailing: all.count > 1 ? Array(all.dropFirst()) : all
        }
        HStack(spacing: 6) {
            ForEach(Array(shown.enumerated()), id: \.offset) { _, part in
                view(part)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private func view(_ part: Part) -> some View {
        switch part {
        case .art:
            if let art {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.artSize, height: Self.artSize)
                    .clipShape(RoundedRectangle(cornerRadius: Self.artRadius, style: .continuous))
                    .accessibilityHidden(true)
            }
        case .bars:
            MusicBars(color: Color(Self.barsColor(tint)), count: 5, height: 12)
        case .platy:
            if let platy { PlatyView(mood: platy, size: PlatyEarFit.platy, morphID: MorphID.platy) }
        case .appIcon:
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Self.appIconSize, height: Self.appIconSize)
                    .accessibilityHidden(true)
            }
        case .name(let s):
            PillLeadText(text: s, amber: false)
        case .text(let s):
            PillLeadText(text: s, amber: true)
        }
    }
}
