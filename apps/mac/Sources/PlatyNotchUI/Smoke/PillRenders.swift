import AppKit
import PlatyNotchKit
import SwiftUI

/// The compact pill in its important states, for the smoke renders and the hidden
/// `--pill-gallery <dir>` review (every state at every pill width, beside a 14-inch
/// MacBook Pro notch and on a screen without one). Fixed data, nothing read.
@MainActor
enum PillRenders {
    enum Scene: String, CaseIterable {
        case idle, agents, needsYou = "needs-you", music, timer, paused, approval
    }

    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(_ i: Int, _ state: SessionState, agent: String) -> Session {
        Session(key: "s\(i)", agent: agent, agentName: agent, sessionID: "s\(i)", state: state,
                startedAt: start, updatedAt: start)
    }

    /// Twelve sessions over four agents, all working (or one waiting).
    static func sessions(_ count: Int, waiting: Int? = nil) -> [Session] {
        let agents = ["claude-code", "codex", "cursor", "gemini"]
        return (0..<count).map { i in session(i, i == waiting ? .waitingInput : .active, agent: agents[i % agents.count]) }
    }

    static let music = LiveActivity(id: "music:playing", widgetID: "music", priority: LivePriority.musicPlaying,
                                    glyph: .musicBars, tint: .accent, accessibilityLabel: "Music playing", title: "Music")
    static let paused = LiveActivity(id: "music:paused", widgetID: "music", priority: LivePriority.musicPlaying,
                                     glyph: .symbol("pause.fill"), tint: .neutral, accessibilityLabel: "Music paused",
                                     title: "Music")
    static func timer() -> LiveActivity {
        let end = Date().addingTimeInterval(4 * 60 + 59.5)
        return LiveActivity(id: "time:timer:1", widgetID: "time", priority: LivePriority.timerRunning,
                            glyph: .symbol("timer"), tint: .accent, countdownTo: end, accessibilityLabel: "Timer running",
                            title: "Tea")
    }
    static let download = LiveActivity(id: "download", widgetID: "system", priority: LivePriority.download,
                                       glyph: .symbol("arrow.down.circle"), tint: .neutral,
                                       accessibilityLabel: "Downloading", title: "Download")

    /// What the pill shows in `scene`, and Platy's mood.
    static func content(_ scene: Scene) -> (PillContent, PlatyMood) {
        let now = Date()
        func make(_ a: [LiveActivity], _ s: [Session], approvals: Int = 0) -> PillContent {
            PillContent(activities: a, sessions: s, approvals: approvals, hiddenKinds: [], now: now)
        }
        switch scene {
        case .idle: return (make([], []), .idle)
        case .agents: return (make([], sessions(12)), .working)
        case .needsYou: return (make([], sessions(3, waiting: 1)), .waiting)
        case .music: return (make([music], sessions(2)), .workingToMusic)
        case .timer: return (make([timer(), music, download], sessions(1)), .working)
        case .paused: return (make([paused], []), .idle)
        case .approval:
            var s = sessions(2)
            s[0].state = .blocked
            return (make([music], s, approvals: 1), .waiting)
        }
    }

    static func notchLayout(_ width: AppearanceSettings.PillWidth) -> PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
                    auxLeft: CGRect(x: 0, y: 950, width: 654, height: 32),
                    auxRight: CGRect(x: 858, y: 950, width: 654, height: 32), pillWidth: width)
    }

    static func plainLayout(_ width: AppearanceSettings.PillWidth) -> PanelLayout {
        PanelLayout(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055),
                    auxLeft: nil, auxRight: nil, pillWidth: width)
    }

    /// The resting pill at `width`: beside a notch (drawn dark grey here so its edges show;
    /// black in the app, and the pill is dark in every theme there, as in the app) or on a
    /// screen without one (following the scheme).
    static func pill(_ scene: Scene, width: AppearanceSettings.PillWidth, notch: Bool,
                     liveSide: LiveSide = .right) -> AnyView {
        let (content, mood) = Self.content(scene)
        let layout = notch ? notchLayout(width) : plainLayout(width)
        let rect = layout.contentRect(for: .compact)
        let pill = CompactPill(content: content, connection: .connected, hasNotch: layout.hasNotch,
                               notchWidth: layout.hasNotch ? layout.anchor.width : 0, liveSide: liveSide,
                               earWidth: layout.liveEarWidth, platy: mood)
        if notch {
            // The shape is drawn, not clipped: a capture (`cacheDisplay`) of a clipped
            // SF Symbol loses its tint (the window server keeps it), and nothing in the
            // pill reaches its edge anyway.
            let view = ZStack {
                Theme.panelShape(hasNotch: true).fill(Color(PanelPalette.darkSurface))
                Color(white: 0.2).frame(width: layout.anchor.width)
                pill
            }
            .frame(width: rect.width, height: rect.height)
            .environment(\.colorScheme, .dark)
            .environment(\.panelTicking, false)
            return AnyView(view)
        }
        // A still: a ticking countdown is a TimelineView, which a capture draws faded.
        let view = PlainPill(pill: pill, size: rect.size).environment(\.panelTicking, false)
        return AnyView(view)
    }

    /// Every scene at every width, beside a notch and without one: (name, view).
    static func gallery() -> [(String, AnyView)] {
        var out: [(String, AnyView)] = []
        for scene in Scene.allCases {
            for width in AppearanceSettings.PillWidth.allCases {
                out.append(("pill-\(scene.rawValue)-\(width.rawValue)-notch", pill(scene, width: width, notch: true)))
                out.append(("pill-\(scene.rawValue)-\(width.rawValue)-plain", pill(scene, width: width, notch: false)))
            }
            out.append(("pill-\(scene.rawValue)-standard-notch-liveleft",
                        pill(scene, width: .standard, notch: true, liveSide: .left)))
        }
        out.append(("pill-sheet", AnyView(sheet())))
        return out
    }

    /// Every scene in one image: a row per scene, the three widths beside a notch, then
    /// without one, then Standard with the live ear on the left.
    private static func sheet() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Scene.allCases, id: \.self) { scene in
                HStack(spacing: 14) {
                    Text(verbatim: scene.rawValue)
                        .font(DS.font(TypeScale.caption))
                        .frame(width: 70, alignment: .leading)
                    ForEach(AppearanceSettings.PillWidth.allCases, id: \.self) { w in
                        pill(scene, width: w, notch: true)
                    }
                    ForEach(AppearanceSettings.PillWidth.allCases, id: \.self) { w in
                        pill(scene, width: w, notch: false)
                    }
                    pill(scene, width: .standard, notch: true, liveSide: .left)
                }
            }
        }
    }

    /// `--pill-gallery <dir>`: writes `<name>-<dark|light>.png` for `gallery()` and
    /// anything `extra` adds; returns the number written.
    static func writeGallery(to dir: URL, extra: [(String, AnyView)] = []) -> Result<Int, PlatyRenders.Failure> {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(PlatyRenders.Failure(message: "cannot create \(dir.path)"))
        }
        var count = 0
        for scheme in [ColorScheme.dark, .light] {
            for (name, view) in gallery() + extra {
                let url = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                guard let png = ThemeRenders.renderHosted(view, scheme: scheme, settle: 0.3) else {
                    return .failure(PlatyRenders.Failure(message: "\(name) did not render"))
                }
                do { try png.write(to: url) } catch {
                    return .failure(PlatyRenders.Failure(message: "cannot write \(url.path)"))
                }
                count += 1
            }
        }
        return .success(count)
    }
}

/// A pill on a screen without a notch: the themed surface, fully rounded.
private struct PlainPill: View {
    let pill: CompactPill
    let size: CGSize
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        pill
            .frame(width: size.width, height: size.height)
            .background(Theme.panelShape(hasNotch: false).fill(Theme.surface(scheme)))
            // Its edge, which on the render's matching background would not show.
            .overlay(Theme.panelShape(hasNotch: false).stroke(Color.gray.opacity(0.5), lineWidth: 1))
    }
}

/// Frames of the real open/close morph (`PanelRootView` in an off-screen window beside a
/// 14-inch notch), captured while the mode change animates: for `--pill-gallery`.
@MainActor
enum MorphRenders {
    /// The scenes: agents working (Platy grows into the agents hero), a timer alone (the
    /// pill's timer glyph grows into the hero's), and agents under Reduced (a cross-fade).
    enum Scene: String, CaseIterable {
        case agents, timer, reduced
    }

    /// Seconds after the mode change for the start, middle and end frames.
    static let times: [(String, Double)] = [("start", 0.0), ("middle", 0.08), ("end", 0.8)]

    /// Writes `morph-<scene>-<open|close>-<start|middle|end>-<dark|light>.png`; returns how many.
    static func write(to dir: URL) -> Result<Int, PlatyRenders.Failure> {
        var count = 0
        for scene in Scene.allCases {
            for theme in [AppearanceSettings.Theme.dark, .light] {
                for open in [true, false] {
                    let shots = capture(scene, theme: theme, open: open)
                    for ((label, _), data) in zip(times, shots) {
                        let name = "morph-\(scene.rawValue)-\(open ? "open" : "close")-\(label)-\(theme == .dark ? "dark" : "light").png"
                        guard let data else { return .failure(PlatyRenders.Failure(message: "\(name) did not render")) }
                        do { try data.write(to: dir.appendingPathComponent(name)) } catch {
                            return .failure(PlatyRenders.Failure(message: "cannot write \(name)"))
                        }
                        count += 1
                    }
                }
            }
        }
        return .success(count)
    }

    private static func rig(_ scene: Scene) -> NowRenders.Rig {
        switch scene {
        case .agents, .reduced: NowRenders.agentsHero()
        case .timer:
            NowRenders.timerHero()
        }
    }

    /// The panel from compact to open (or back), captured at `times`.
    static func capture(_ scene: Scene, theme: AppearanceSettings.Theme, open: Bool) -> [Data?] {
        let rig = rig(scene)
        rig.store.apply(.connected)   // the live ear shows the item, not the reconnecting glyph
        let model = PanelViewModel()
        let layout: PanelLayout = NowRenders.layout
        model.layout = layout
        model.visible = true
        model.mode = open ? .compact : .expanded
        var appearance = AppearanceSettings()
        appearance.theme = theme
        appearance.motion = scene == .reduced ? .reduced : .calm
        model.appearance = appearance
        let root = PanelRootView(model: model, store: rig.store, responder: ApprovalResponder(client: rig.client),
                                 today: rig.today, widgets: rig.registry, memory: MemoryServices(client: rig.client),
                                 extraTabs: [], onOpenTerminal: { _ in })
            .environment(\.platyMood, rig.mood)
        let size: CGSize = layout.windowFrame.size
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: size)
        // Off screen, like every render window: never shown on the user's display.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: 10_000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        window.backgroundColor = theme == .light ? NSColor(white: 0.7, alpha: 1) : NSColor(white: 0.45, alpha: 1)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        // Warm up with one open and close: the first open builds every view of the panel,
        // which would stall the frames being captured.
        model.mode = open ? .expanded : .compact
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        model.mode = open ? .compact : .expanded
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        model.mode = open ? .expanded : .compact
        let start = Date()
        var out: [Data?] = []
        for (_, t) in times {
            RunLoop.main.run(until: start.addingTimeInterval(t))
            out.append(snapshot(host))
        }
        return out
    }

    /// The layer tree with its animations applied (presentation values: a frame
    /// mid-animation), at 2x. Layer rendering leaves out masks, so content is not clipped
    /// to the panel's rounded corners here.
    private static func snapshot(_ view: NSView) -> Data? {
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        let w = Int(view.bounds.width * scale)
        let h = Int(view.bounds.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if let bg = view.window?.backgroundColor.cgColor {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        ctx.scaleBy(x: scale, y: scale)
        // The hosting view's layer is flipped (y down); the bitmap context is not.
        ctx.translateBy(x: 0, y: view.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        (layer.presentation() ?? layer).render(in: ctx)
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
