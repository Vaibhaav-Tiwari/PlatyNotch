import AppKit
import PlatyNotchKit
import SwiftUI

/// `--render-showcase <dir>`: the five Quiet Notch scenes (wireframes A–C, E), each the open
/// panel as it really looks on a 14-inch MacBook Pro (600 pt wide, always black, the band
/// level with the camera housing), hanging from a drawn menu bar and notch over a calm
/// gradient wallpaper drawn here in code (no third-party image, no Apple wallpaper), 16:9 at
/// 2x, on a dark and a light desktop: Home with music, Home with live chips, Agents, an
/// approval above the Agents rows, and the command line. Agents show their names (renders
/// never carry an app's icon). The same inert models as the theme renders: nothing is
/// read, played or saved.
@MainActor
enum ShowcaseRenders {
    static let scenes = ["home-music", "home-live", "agents", "approval", "command-line"]
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
                let s = scene(name)
                let picture = ShowcaseDesktop(scheme: scheme, time: s.time) {
                    panel(s.content, height: s.height)
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
        var header: HeaderServices?
        var command: String?
        var panelNow: Date? = now
        switch name {
        case "home-music":
            rig = homeRig(at: now, live: false)
        case "home-live":
            rig = homeRig(at: now, live: true)
            // Two hours of keep awake started 40 minutes ago: "1:20" left (wireframe B).
            header = HomeRenders.headerServices(keepAwake: true,
                                                battery: BatteryState(percent: 64, charging: true, pluggedIn: true,
                                                                      minutesRemaining: nil),
                                                startedAt: now.addingTimeInterval(-40 * 60))
        case "agents":
            rig = agentsRig(at: now)
            route = PanelRoute(destination: .agents)
        case "approval":
            // The card's countdown runs on the real clock (as in the app), so the approval is
            // 20 s old in real time; the rows' ages count from the real clock too.
            rig = agentsRig(at: Date())
            try? rig.store.apply(Envelope.make(.approvalAdded, bashApproval()))
            route = PanelRoute(destination: .agents)
            panelNow = nil
        default:
            rig = homeRig(at: now, live: false)
            command = "timer 10m tea"
        }
        rig.store.apply(.connected)
        let content = HomeRenders.panel(rig, route: route, command: command, now: panelNow, header: header)
        let measured: CGFloat = NSHostingView(rootView: content).fittingSize.height
        return Scene(content: content, height: measured, time: now)
    }

    /// Home at `now`: Weightless playing with drawn artwork, the weather in the header, and Up
    /// next as in wireframe A (a meeting in 45 minutes, a timed reminder, one overdue). `live`
    /// adds wireframe B's chips: focus, a tea timer and the shelf.
    static func homeRig(at now: Date, live: Bool) -> HomeRenders.Rig {
        var rig = HomeRenders.builtIns(meeting: false, at: now)
        rig.mood = .idle
        rig.today.nowPlaying.debugApply(NowPlayingInfo(bundleIdentifier: "com.apple.Music", title: "Weightless",
                                                       artist: "Marconi Union", isPlaying: true, artwork: artwork(),
                                                       elapsed: 161, duration: 473, rate: 0, timestamp: now), now: now)
        let meeting = CalendarMeeting(id: "design", title: "Design review", start: now.addingTimeInterval(45 * 60),
                                      end: now.addingTimeInterval(75 * 60))
        rig.today.calendar.setForTesting(access: .granted, meetings: [meeting])
        let cal = Calendar.current
        let five = cal.date(bySettingHour: 17, minute: 0, second: 0, of: now) ?? now
        let yesterday = cal.date(byAdding: .day, value: -1, to: now) ?? now
        let reminders = [ReminderItem(id: "priya", title: "Call Priya", due: five, hasTime: true),
                         ReminderItem(id: "invoice", title: "Send invoice", due: yesterday, hasTime: true)]
        (rig.registry.widget(RemindersWidget.widgetID) as? RemindersWidget)?.reminders
            .setForTesting(access: .granted, items: reminders)
        (rig.registry.widget(WeatherWidget.widgetID) as? WeatherWidget)?.showForRendering(
            place: GeoPlace(id: 1, name: "Lisbon", latitude: 38.72, longitude: -9.14),
            weather: WeatherNow(temperatureC: 14, code: 0, isDay: true, time: now, hourly: []))
        if live {
            rig.today.focus.start(minutes: 25, now: now.addingTimeInterval(-(6 * 60 + 18)))
            if let time = rig.registry.widget(TimeWidget.widgetID) as? TimeWidget {
                _ = time.startTimer(duration: 190, label: "Tea")
            }
            (rig.registry.widget(ShelfWidget.widgetID) as? ShelfWidget)?.showForRendering([
                ShelfItem(kind: .text("Release checklist"), addedAt: now),
                ShelfItem(kind: .text("Meeting notes"), addedAt: now),
                ShelfItem(kind: .url(URL(string: "https://example.com/report")!), addedAt: now),
            ])
        }
        return rig
    }

    /// Wireframe C: three sessions in three apps, usage in the header, two open loops.
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

    /// A short Bash command (wireframe C's card).
    static func bashApproval() -> Approval {
        let created = Date().addingTimeInterval(-20)
        let command = "rm -rf ./build && npm test -- --grep \"panel\""
        return Approval(id: "showcase-bash", sessionKey: "tests", agent: "claude-code", agentName: "Claude Code",
                        project: "platynotch", tool: "Bash", summary: command,
                        input: RawJSON(.object(["command": .string(command)])), createdAt: created,
                        expiresAt: created.addingTimeInterval(300))
    }

    /// Original artwork drawn in code: two soft fields, nothing from a real cover.
    static func artwork() -> Data? {
        let size = NSSize(width: 108, height: 108)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGradient(colors: [NSColor(srgbRed: 0.23, green: 0.29, blue: 0.39, alpha: 1),
                                NSColor(srgbRed: 0.64, green: 0.44, blue: 0.48, alpha: 1)])?
                .draw(in: rect, angle: -45)
            NSColor(white: 1, alpha: 0.12).setFill()
            NSBezierPath(ovalIn: CGRect(x: 52, y: 14, width: 64, height: 64)).fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
