import AppKit
import PlatyNotchKit
import SwiftUI

/// Where an agent's icon comes from (user change: agent icons): the agent's own Mac app,
/// already installed on this Mac, looked up by the fixed allowlist in
/// `AgentBrand.appBundleIDs`. Nothing is bundled. Each agent is looked up once, the first
/// time a visible view asks (the Agents list, the agents hero, the hover peek), and the
/// answer (a miss too) is kept; nothing polls.
final class AgentIconSource: @unchecked Sendable {
    typealias Lookup = (String) -> NSImage?

    /// The running app's: NSWorkspace, on this Mac. Misses are forgotten when any app
    /// launches (an agent app installed and opened while PlatyNotch runs); nothing polls.
    static let installed: AgentIconSource = {
        let source = AgentIconSource(lookup: AgentIconSource.workspaceIcon)
        source.launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak source] _ in source?.clearMisses() }
        return source
    }()
    /// Monograms only (renders, so they are the same on every Mac).
    static let monogramsOnly = AgentIconSource(lookup: { _ in nil })

    private let lookup: Lookup
    private let lock = NSLock()
    /// Guarded by `lock`: brand key → icon, or nil for "not installed".
    private var cache: [String: NSImage?] = [:]
    private var launchObserver: NSObjectProtocol?

    init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    /// The installed app's icon for `brand`, or nil (show the monogram).
    func icon(for brand: AgentBrand) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[brand.key] { return hit }
        var found: NSImage?
        for id in brand.appBundleIDs {
            if let image = lookup(id) { found = image; break }
        }
        cache[brand.key] = .some(found)
        return found
    }

    /// Forgets the agents found missing, so the next visible view looks again.
    func clearMisses() {
        lock.lock()
        defer { lock.unlock() }
        cache = cache.filter { $0.value != nil }
    }

    private static func workspaceIcon(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

extension EnvironmentValues {
    /// Where agent icons come from (renders and tests pass `.monogramsOnly` or a fake).
    @Entry var agentIcons: AgentIconSource = .installed
}

/// An agent's 28 pt identity icon (its installed app's icon, else a monogram on the
/// agent's colour) with the session's state as a small monochrome symbol badge at the
/// bottom right. The row or chip beside it always says the state in words too.
struct AgentBadge: View {
    enum Face: Equatable {
        case app
        case monogram(String)
    }

    let brand: AgentBrand
    /// nil: no state badge (the usage chips).
    let tone: StateTone?
    var size: CGFloat = 28
    @Environment(\.agentIcons) private var icons
    @Environment(\.colorScheme) private var scheme

    init(brand: AgentBrand, tone: StateTone?, size: CGFloat = 28) {
        self.brand = brand
        self.tone = tone
        self.size = size
    }

    /// The plan's form: an agent identity and a state.
    init(agent: AgentIdentity, tone: StateTone) {
        self.init(brand: AgentBrand(agent: agent.rawValue), tone: tone)
    }

    static func face(for brand: AgentBrand, source: AgentIconSource) -> Face {
        source.icon(for: brand) == nil ? .monogram(brand.monogram) : .app
    }

    var body: some View {
        face
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if let tone {
                    StateBadge(tone: tone).offset(x: StateBadge.overhang, y: StateBadge.overhang)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var face: some View {
        if let image = icons.icon(for: brand) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
        } else {
            let dark: Bool = scheme != .light
            let radius: CGFloat = size * 0.25
            let textSize: CGFloat = max(TypeScale.minimum, 13 * size / 28)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color(brand.background(dark: dark)))
                .overlay {
                    Text(verbatim: brand.monogram)
                        .font(.system(size: textSize, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(brand.ink(dark: dark).rgb))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
        }
    }
}

/// A session state as one monochrome SF Symbol on a 16 pt circle of the panel surface
/// with a 1 pt keyline, the way macOS draws its own status badges.
struct StateBadge: View {
    static let size: CGFloat = 16
    /// How far the badge sits past the icon's corner (its centre 2 pt inside the corner),
    /// so it covers the corner, not the monogram.
    static let overhang: CGFloat = 6
    let tone: StateTone
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark: Bool = scheme != .light
        let surface: RGB = dark ? PanelPalette.panelDark : PanelPalette.lightSurface
        let keyline: Color = dark ? Color.white.opacity(0.18) : Color.black.opacity(0.18)
        Circle()
            .fill(Color(surface))
            .overlay(Circle().strokeBorder(keyline, lineWidth: 1))
            .overlay {
                Image(systemName: tone.symbol)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.color(tone, scheme))
            }
            .frame(width: Self.size, height: Self.size)
            .accessibilityHidden(true)
    }
}
