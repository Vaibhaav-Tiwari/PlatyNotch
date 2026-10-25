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
