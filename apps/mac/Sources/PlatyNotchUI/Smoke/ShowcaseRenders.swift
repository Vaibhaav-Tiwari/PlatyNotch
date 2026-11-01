import AppKit
import PlatyNotchKit
import SwiftUI

/// `--render-showcase <dir>`: the six Island scenes (wireframes A–F), each the open panel as
/// it really looks on a 14-inch MacBook Pro (always black, the band level with the camera
/// housing), hanging from a drawn menu bar and notch over a calm gradient wallpaper drawn
/// here in code (no third-party image, no Apple wallpaper), 16:9, forced to 2x, on a dark
/// and a light desktop: Home on a sunny afternoon, Home on a rainy night, the Timer tool,
/// the search, Agents with its usage rings, and the closed pill's three leads. Agents show
/// their names (renders never carry an app's icon). The same inert models as the theme
/// renders: nothing is read, played or saved.
@MainActor
enum ShowcaseRenders {
    static let scenes = ["home-sunny", "home-rain-night", "tool-timer", "search", "agents", "pill"]
    /// The scenes' clock: today at 14:59, so a regeneration shows the same times.
    static var clock: Date {
        Calendar.current.date(bySettingHour: 14, minute: 59, second: 0, of: Date()) ?? Date()
    }

    /// The picture, 16:9 (points; written at 2x).
    static let canvas = CGSize(width: 800, height: 450)

    static func write(to dir: URL) -> Result<Int, ThemeRenders.RenderError> {
        AgentsRenders.withHostNames { writeAll(to: dir) }
    }

    private static func writeAll(to dir: URL) -> Result<Int, ThemeRenders.RenderError> {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(ThemeRenders.RenderError(message: "cannot create \(dir.path)"))
        }
        var count = 0
        for scheme in [ColorScheme.dark, .light] {
            for name in scenes {
                let file = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                let data: Data?
                if name == "pill" {
                    data = render(ShowcaseDesktop(scheme: scheme, time: clock) { pills() }, scheme: scheme)
                } else {
                    let s = scene(name)
                    data = render(ShowcaseDesktop(scheme: scheme, time: s.time) { panel(s.content, height: s.height) },
                                  scheme: scheme)
                }
                guard let png = data else {
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
        /// The panel's content height (the panel hugs it, as the live panel does).
        let height: CGFloat
        /// The menu bar clock.
        let time: Date
    }

    /// A scene's content (what `HomeRenders.panel` lays out below the housing), connected
    /// to the core so the header is quiet.
    static func scene(_ name: String) -> Scene {
        let now = clock
        var rig: HomeRenders.Rig
        var route = PanelRoute(destination: .home)
        var command: String?
        var time: Date = now
        var panelNow: Date? = now
        switch name {
        case "home-rain-night":
            // Wireframe B: nothing playing (Resume), a rainy night, a free evening.
            time = Calendar.current.date(bySettingHour: 21, minute: 12, second: 0, of: now) ?? now
            rig = HomeRenders.island(playing: false, sky: HomeRenders.reading(61, day: false, 17, at: time, rainy: true),
                                     now: time, next: [])
        case "tool-timer":
            // Wireframe C: the Timer tool with a tea and a laundry timer running (real clock).
            rig = ToolRenders.runningTimers()
            route = PanelRoute(destination: .home, tool: PanelTools.timer)
            panelNow = nil   // the timers run on the real clock
        case "search":
            // Wireframe D: the full-panel search, nothing typed yet: every tool and command.
            rig = HomeRenders.homeRest(at: now)
            command = ""
        case "agents":
            // Wireframe E: three sessions in three apps, the usage rings, two open loops.
            rig = agentsRig(at: now)
            route = PanelRoute(destination: .agents)
        default:
            // Wireframe A: Green Light playing, sunny in Bengaluru, a meeting in 45 minutes.
            rig = HomeRenders.homeRest(at: now)
        }
        rig.mood = .idle
        rig.store.apply(.connected)
        let content = HomeRenders.panel(rig, route: route, command: command, now: panelNow ?? Date(),
                                        full: command != nil)
        let measured: CGFloat = NSHostingView(rootView: content).fittingSize.height
        return Scene(content: content, height: measured, time: time)
    }

    /// Wireframe F: the closed pill's three leads, music at the notch and the timer and
    /// needs-you leads below it, each as it sits under the camera housing.
    static func pills() -> some View {
        let leads: [PillLead] = [.music, .timer(remaining: "18:42"), .needsYou(sessionID: "s1")]
        // Below the menu bar, each pill drawn as it sits beside a 14-inch MacBook Pro's housing.
        return VStack(spacing: 32) {
            ForEach(Array(leads.enumerated()), id: \.offset) { _, lead in
                PillRenders.lead(lead, width: .standard, greyNotch: false)
                    .clipShape(Theme.panelShape(hasNotch: false))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            }
        }
        .padding(.top, HomeRenders.layout.anchor.height + 56)
        .environment(\.agentIcons, .namesOnly)
    }

    /// Wireframe E: three sessions in three apps, usage rings in the header, two open loops.
    static func agentsRig(at now: Date) -> HomeRenders.Rig {
        let s = AgentsRenders.session
        let start = now.addingTimeInterval(-12 * 60)
        var tests = s("tests", "claude-code", "Claude Code", "platynotch", .active, "Running tests", "Bash", nil, 0,
                      "com.anthropic.claudefordesktop")
        tests.startedAt = start
        tests.updatedAt = now
        var ask = s("ask", "claude-code", "Claude Code", "agent-orchestrator", .waitingInput, nil, "AskUserQuestion", nil,
                    0, "com.mitchellh.ghostty")
        ask.updatedAt = now.addingTimeInterval(-3 * 60)
        var done = s("done", "codex", "Codex", "brian2", .idle, nil, "Write", nil, 0, "com.apple.Terminal")
        done.updatedAt = now.addingTimeInterval(-62 * 60)
        let rig = AgentsRenders.rig([tests, ask, done])
        return rig
    }

    /// The open panel around `content` (`height` tall), as `PanelRootView` draws it: always
    /// black, 22 pt bottom corners, the content below the housing with the panel's padding.
    static func panel(_ content: AnyView, height: CGFloat) -> some View {
        let layout = HomeRenders.layout
        let width: CGFloat = PanelLayout.expandedSize.width
        let top: CGFloat = layout.contentInset(for: .expanded)
        let total: CGFloat = top + height + Space.panelBottom
        return ZStack(alignment: .top) {
            Theme.surface
            content
                .padding(EdgeInsets(top: top, leading: Space.panelSide, bottom: Space.panelBottom,
                                    trailing: Space.panelSide))
        }
        .frame(width: width, height: total, alignment: .top)
        .clipShape(Theme.panelShape(hasNotch: true, open: true))
        .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
        .environment(\.colorScheme, .dark)
        .environment(\.agentIcons, .namesOnly)
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
    private var barHeight: CGFloat { HomeRenders.layout.anchor.height }
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

    /// Soft slate and dusk fields, darker on the dark desktop; nothing photographic.
    private var wallpaper: some View {
        let dark: Bool = scheme == .dark
        let top = Color(RGB(hex: dark ? 0x1A2230 : 0xD6DEE8))
        let bottom = Color(RGB(hex: dark ? 0x1B1A2E : 0xE9E1D4))
        let slateGlow = Color(RGB(hex: dark ? 0x2E4560 : 0xAFC3D9))
        let duskGlow = Color(RGB(hex: dark ? 0x3B2E4F : 0xF2D9C0))
        return ZStack {
            LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [slateGlow.opacity(0.75), slateGlow.opacity(0)], center: UnitPoint(x: 0.15, y: 0.85),
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
