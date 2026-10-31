import AppKit
import PlatyNotchKit
import SwiftUI

/// Where an agent's icon comes from: the agent's own Mac app,
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
    /// No icons: every agent shows its name (renders, so they are the same on every Mac and
    /// never carry a third-party logo).
    static let namesOnly = AgentIconSource(lookup: { _ in nil })

    private let lookup: Lookup
    private let lock = NSLock()
    /// Guarded by `lock`: brand key → icon, or nil for "not installed".
    private var cache: [String: NSImage?] = [:]
    private var launchObserver: NSObjectProtocol?

    init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    /// The installed app's icon for `brand`, or nil (show the name).
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
    /// Where agent icons come from (renders and tests pass `.namesOnly` or a fake).
    @Entry var agentIcons: AgentIconSource = .installed
}

/// An agent's identity (Quiet Notch spec 5.3): its installed app's icon at 16 pt with no
/// background, else its name as plain text. Never initials, never a tinted square. The row or
/// card beside it says the state with a dot and words.
struct AgentBadge: View {
    enum Face: Equatable {
        case app
        case name(String)
    }

    static let size: CGFloat = IconSize.header
    let brand: AgentBrand
    /// Without an icon, show nothing (the approval card, which names the agent itself).
    var nameFallback: Bool = true
    @Environment(\.agentIcons) private var icons

    static func face(for brand: AgentBrand, source: AgentIconSource) -> Face {
        source.icon(for: brand) == nil ? .name(brand.displayName) : .app
    }

    /// The Agents list's first column: 18 pt while every agent has its app icon, else as wide
    /// as the longest name shown (at most 84 pt), so the projects line up.
    static func column(for brands: [AgentBrand], source: AgentIconSource) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TypeScale.secondary.size)
        var width: CGFloat = AgentRow.badgeColumn
        for brand in brands where source.icon(for: brand) == nil {
            let text: CGFloat = (brand.displayName as NSString).size(withAttributes: [.font: font]).width
            width = max(width, ceil(text) + 2)
        }
        return min(width, 84)
    }

    var body: some View {
        if let image = icons.icon(for: brand) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: Self.size, height: Self.size)
                .accessibilityHidden(true)
        } else if nameFallback {
            Text(verbatim: brand.displayName)
                .font(DS.font(TypeScale.secondary))
                .foregroundStyle(DS.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityHidden(true)
        }
    }
}
