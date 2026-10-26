import AppKit
import PlatyNotchKit
import SwiftUI

/// `--render-showcase <dir>` (spec 12): the five hero scenes as the open panel really looks
/// on a 14-inch MacBook Pro (560 x 380 with the pure-black band level with the camera
/// housing), at 2x, dark and light, on a transparent background: Now with music, Now with
/// an agent working, an approval with its diff, the Library and Platy's idle pond.
/// The same inert models as the theme renders: nothing is read, played or saved.
@MainActor
enum ShowcaseRenders {
    static let scenes = ["now-music", "now-agent", "approval-diff", "library", "platy-idle"]

    static func write(to dir: URL) -> Result<Int, ThemeRenders.RenderError> {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(ThemeRenders.RenderError(message: "cannot create \(dir.path)"))
        }
        var count = 0
        for scheme in [ColorScheme.dark, .light] {
            for name in scenes {
                let file = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                guard let png = render(panel(scene(name), scheme: scheme), scheme: scheme) else {
                    return .failure(ThemeRenders.RenderError(message: "\(name) did not render"))
                }
                do { try png.write(to: file) } catch {
                    return .failure(ThemeRenders.RenderError(message: "cannot write \(file.path)"))
                }
                count += 1
            }
        }
        return .success(count)
    }

    /// A scene's content (what `NowRenders.panel` lays out below the housing), connected
    /// to the core so the header is quiet.
    static func scene(_ name: String) -> AnyView {
        var rig: NowRenders.Rig
        var route = PanelRoute(destination: .now)
        var now: Date?
        switch name {
        case "now-music":
            rig = NowRenders.musicHero()
            rig.mood = PlatyMoodResolver.mood(sessions: [], approvalsPending: 0, musicPlaying: true, focusActive: false,
                                              justFinished: false, hour: 14)
        case "now-agent":
            rig = NowRenders.agentsHero()
        case "approval-diff":
            rig = AgentsRenders.approvals([AgentsRenders.editApproval("e1")])
            route = PanelRoute(destination: .agents)
        case "library":
            rig = NowRenders.everythingOn()
            route = PanelRoute(destination: .library)
        default:
            let evening = NowRenders.at(hour: 19)
            rig = NowRenders.builtIns(meeting: false, at: evening)
            now = evening
        }
        rig.store.apply(.connected)
        return NowRenders.panel(rig, route: route, now: now)
    }

    /// The open panel around `content`, as `PanelRootView` draws it.
    static func panel(_ content: AnyView, scheme: ColorScheme) -> some View {
        let layout = NowRenders.layout
        let size = PanelLayout.expandedSize
        let top: CGFloat = layout.contentInset(for: .expanded)
        let band: CGFloat = layout.anchor.height
        let shape = Theme.panelShape(hasNotch: true)
        return ZStack(alignment: .top) {
            Theme.surface(scheme, mode: .expanded, hasNotch: true, style: .opaque)
            Color(PanelPalette.darkSurface).frame(height: band)
            content
                .padding(EdgeInsets(top: top, leading: Space.panelMargin, bottom: 10, trailing: Space.panelMargin))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .environment(\.colorScheme, scheme)
        .environment(\.agentIcons, .monogramsOnly)
    }

    /// Drawn by an off-screen hosting view at 2x (Platy and the pond are layers).
    private static func render<V: View>(_ view: V, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        let size = PanelLayout.expandedSize
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.display()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
