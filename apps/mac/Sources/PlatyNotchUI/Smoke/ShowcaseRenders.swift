import AppKit
import PlatyNotchKit
import SwiftUI

/// `--render-showcase <dir>` (spec 12): the five hero scenes, each the open panel as it
/// really looks on a 14-inch MacBook Pro (560 pt wide, the pure-black band level with the
/// camera housing), hanging from a drawn menu bar and notch over a calm gradient wallpaper
/// drawn here in code (no third-party image, no Apple wallpaper), 16:9 at 2x, dark and
/// light: Now with music, Now with an agent working, an approval with its diff, the Library
/// and Platy's idle pond. The same inert models as the theme renders: nothing is read,
/// played or saved.
@MainActor
enum ShowcaseRenders {
    static let scenes = ["now-music", "now-agent", "approval-diff", "library", "platy-idle"]
    /// The scenes' clock: today at 14:59 (the pond at 19:12), so a regeneration shows the
    /// same times.
    static var clock: Date {
        Calendar.current.date(bySettingHour: 14, minute: 59, second: 0, of: Date()) ?? Date()
    }

    /// The picture, 16:9 (points; written at 2x).
    static let canvas = CGSize(width: 800, height: 450)

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
                let s = scene(name)
                let picture = ShowcaseDesktop(scheme: scheme, time: s.time) {
                    panel(s.content, height: s.height, scheme: scheme)
                }
                guard let png = render(picture, scheme: scheme) else {
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

    struct Scene {
        let content: AnyView
        /// The panel's height, cropped to its content (no empty band under the last row).
        let height: CGFloat
        /// The menu bar clock.
        let time: Date
    }

    /// A scene's content (what `NowRenders.panel` lays out below the housing), connected
    /// to the core so the header is quiet.
    static func scene(_ name: String) -> Scene {
        let now = clock
        var rig: NowRenders.Rig
        var route = PanelRoute(destination: .now)
        var time: Date = now
        var height: CGFloat = 352
        switch name {
        case "now-music":
            rig = NowRenders.musicHero(at: now)
            rig.mood = PlatyMoodResolver.mood(sessions: [], approvalsPending: 0, musicPlaying: true, focusActive: false,
                                              justFinished: false, hour: 14)
        case "now-agent":
            rig = NowRenders.agentsHero(at: now)
        case "approval-diff":
            // The card's countdown and the rows' times run on the real clock (as in the app),
            // so the approval is 20 s old in real time; its "4:40" never changes.
            rig = AgentsRenders.approvals([diffApproval()])
            route = PanelRoute(destination: .agents)
            height = PanelLayout.expandedSize.height
        case "library":
            rig = library(at: now)
            route = PanelRoute(destination: .library)
            height = 360
        default:
            time = NowRenders.at(hour: 19)
            rig = NowRenders.pond(hour: 19)
        }
        rig.store.apply(.connected)
        // The approval's rows count from the real clock, like its card; the others use the
        // fixed one.
        let panelNow: Date? = name == "approval-diff" ? nil : time
        return Scene(content: NowRenders.panel(rig, route: route, now: panelNow), height: height, time: time)
    }

    /// A believable Edit: eight lines of Swift with a small, readable change.
    static func diffApproval() -> Approval {
        let old = """
        func refresh(now: Date) {
            let due = timers.filter { $0.end <= now }
            for timer in due {
                ring(timer)
            }
            scheduleWake(after: now)
        }
        """
        let new = """
        func refresh(now: Date) {
            let due = timers.filter { $0.end <= now && !$0.isSnoozed }
            for timer in due where !ringing.contains(timer.id) {
                ring(timer)
            }
            scheduleWake(after: now)
        }
        """
        let created = Date().addingTimeInterval(-20)
        let input: [String: JSONValue] = [
            "file_path": .string("/Users/me/src/platynotch/apps/mac/Sources/PlatyNotchUI/Widgets/TimeWidget.swift"),
            "old_string": .string(old), "new_string": .string(new),
        ]
        return Approval(id: "showcase-edit", sessionKey: "a", agent: "claude-code", agentName: "Claude Code",
                        project: "platynotch", tool: "Edit", summary: "Edit Sources/PlatyNotchUI/Widgets/TimeWidget.swift",
                        input: RawJSON(.object(input)), createdAt: created, expiresAt: created.addingTimeInterval(300))
    }

    /// Twelve tiles, every one set up with something to say: three full rows, so the grid
    /// ends cleanly.
    static func library(at now: Date) -> NowRenders.Rig {
        let rig = NowRenders.builtIns(meeting: true, at: now)
        // Ten widgets, plus Platy Chase and Memory, which are always tools.
        let shown: Set<String> = [MusicWidget.widgetID, MeetingWidget.widgetID, FocusWidget.widgetID, LoopsWidget.widgetID,
                                  TimeWidget.widgetID, ShelfWidget.widgetID, RemindersWidget.widgetID,
                                  WellbeingWidget.widgetID, SystemWidget.widgetID, GamesWidget.widgetID]
        for w in rig.registry.orderedWidgets where !shown.contains(w.id) { rig.registry.setEnabled(w.id, false) }
        rig.today.nowPlaying.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Weightless",
                                                       artist: "Marconi Union", isPlaying: true))
        _ = (rig.registry.widget(TimeWidget.widgetID) as? TimeWidget)?.addTimer("25m")
        (rig.registry.widget(ShelfWidget.widgetID) as? ShelfWidget)?.showForRendering([
            ShelfItem(kind: .text("Release checklist: notarise, tag, appcast"), addedAt: now),
            ShelfItem(kind: .url(URL(string: "https://example.com/specs/library")!), addedAt: now),
        ])
        return rig
    }

    /// The open panel around `content`, as `PanelRootView` draws it, `height` tall.
    static func panel(_ content: AnyView, height: CGFloat, scheme: ColorScheme) -> some View {
        let layout = NowRenders.layout
        let width: CGFloat = PanelLayout.expandedSize.width
        let top: CGFloat = layout.contentInset(for: .expanded)
        let band: CGFloat = layout.anchor.height
        return ZStack(alignment: .top) {
            Theme.surface(scheme, mode: .expanded, hasNotch: true, style: .opaque)
            Color(PanelPalette.darkSurface).frame(height: band)
            content
                .padding(EdgeInsets(top: top, leading: Space.panelMargin, bottom: 10, trailing: Space.panelMargin))
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(Theme.panelShape(hasNotch: true))
        .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.22), radius: 24, y: 10)
        .environment(\.colorScheme, scheme)
        .environment(\.agentIcons, .monogramsOnly)
    }

    /// Drawn by an off-screen hosting view at 2x (Platy and the pond are layers).
    private static func render<V: View>(_ view: V, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: canvas)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: canvas.width, height: canvas.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        host.display()
        // Always 2x, so the committed images are 1600 x 900 on any Mac (CI renders at 1x).
        let size = host.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// A MacBook's top edge: an original gradient wallpaper, the menu bar with the camera
/// notch, and the panel hanging from the notch.
private struct ShowcaseDesktop<Panel: View>: View {
    let scheme: ColorScheme
    let time: Date
    @ViewBuilder let panel: () -> Panel

    /// The 14-inch MacBook Pro's menu bar is as tall as the camera housing.
    private var barHeight: CGFloat { NowRenders.layout.anchor.height }
    private let notchWidth: CGFloat = 186

    var body: some View {
        ZStack(alignment: .top) {
            wallpaper
            menuBar
            panel()
        }
        .frame(width: ShowcaseRenders.canvas.width, height: ShowcaseRenders.canvas.height, alignment: .top)
        .clipped()
        .environment(\.colorScheme, scheme)
    }

    /// Soft teal and slate fields, darker in the dark set; nothing photographic.
    private var wallpaper: some View {
        let dark: Bool = scheme == .dark
        let top = Color(RGB(hex: dark ? 0x10232B : 0xCFE3E2))
        let bottom = Color(RGB(hex: dark ? 0x1B1A2E : 0xE9E1D4))
        let tealGlow = Color(RGB(hex: dark ? 0x1F5C5A : 0x9FD3CB))
        let duskGlow = Color(RGB(hex: dark ? 0x3B2E4F : 0xF2D9C0))
        return ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [tealGlow.opacity(0.75), tealGlow.opacity(0)], center: UnitPoint(x: 0.15, y: 0.85),
                           startRadius: 0, endRadius: 420)
            RadialGradient(colors: [duskGlow.opacity(0.7), duskGlow.opacity(0)], center: UnitPoint(x: 0.9, y: 0.2),
                           startRadius: 0, endRadius: 380)
        }
    }

    private var menuBar: some View {
        let dark: Bool = scheme == .dark
        let ink: Color = dark ? .white : .black
        return ZStack {
            Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))
            HStack(spacing: 14) {
                ForEach(["File", "Edit", "View"], id: \.self) { item in
                    Text(verbatim: item).font(.system(size: 13, weight: .regular))
                }
                Spacer()
                Text(verbatim: time.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.system(size: 13, weight: .regular))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(ink.opacity(0.85))
            .padding(.horizontal, 14)
            // The camera housing.
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(Color.black)
                .frame(width: notchWidth, height: barHeight)
        }
        .frame(height: barHeight)
    }
}
