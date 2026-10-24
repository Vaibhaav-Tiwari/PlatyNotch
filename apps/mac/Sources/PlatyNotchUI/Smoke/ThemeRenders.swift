import AppKit
import PlatyNotchKit
import SwiftUI

/// `--smoke` with `PLATYNOTCH_RENDER_DIR`: renders views that sit on the themed panel
/// surface in both color schemes, the way `PanelRootView` draws them (the scheme in the
/// environment, `Theme.surface(scheme)` behind), and writes `<name>-<scheme>.png`.
/// Inert models only: nothing is read, played or saved.
@MainActor
enum ThemeRenders {
    /// Writes every render; returns the number written, or the first problem.
    static func write(to dir: URL) -> Result<Int, RenderError> {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return .failure(RenderError(message: "cannot create \(dir.path): \(error.localizedDescription)"))
        }
        var count = 0
        for scheme in [ColorScheme.dark, .light] {
            for (name, view, hosted) in views() {
                let url = dir.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                let data = hosted ? renderHosted(view, scheme: scheme) : render(view, scheme: scheme)
                guard let png = data else {
                    return .failure(RenderError(message: "\(name) did not render"))
                }
                do { try png.write(to: url) } catch {
                    return .failure(RenderError(message: "cannot write \(url.path)"))
                }
                count += 1
            }
        }
        return .success(count)
    }

    struct RenderError: Error {
        let message: String
    }

    private static func framed(_ view: AnyView, scheme: ColorScheme) -> some View {
        view
            .padding(12)
            .background(Theme.surface(scheme))
            .environment(\.colorScheme, scheme)
    }

    private static func render(_ view: AnyView, scheme: ColorScheme) -> Data? {
        let renderer = ImageRenderer(content: framed(view, scheme: scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Views holding AppKit views (the shelf card's drag handle), which `ImageRenderer`
    /// draws as a placeholder: an off-screen hosting view's own drawing instead.
    private static func renderHosted(_ view: AnyView, scheme: ColorScheme) -> Data? {
        let host = NSHostingView(rootView: framed(view, scheme: scheme))
        host.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard host.bounds.width > 0, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// (file name, view, needs a hosting view)
    private static func views() -> [(String, AnyView, Bool)] {
        let soon = Date().addingTimeInterval(30)
        let bar = HUDBar(state: HUDState(kind: .volume, level: 0.6, until: soon)).frame(width: 300)
        let hud = HUDView(kind: .volume, level: 0.4, output: "MacBook Pro Speakers").frame(width: 300)   // volume, as the app shows it: with the speaker name (A6)
        let line = HUDIndicator(state: HUDState(kind: .volume, level: 0.7, until: soon)).frame(width: 300, height: 8)
        let shelf = ShelfTile(shelf: ShelfWidget.inert()).frame(width: 360)
        var out: [(String, AnyView, Bool)] = []
        out.append(("hud-bar", AnyView(bar), false))
        out.append(("hud-view", AnyView(hud), false))
        out.append(("hud-indicator", AnyView(line), false))
        out.append(("hud-tile", AnyView(HUDWidget.inert().tileView().frame(width: 360)), false))
        out.append(("approval-card", approvalCard(), false))
        out += games().map { ($0.0, $0.1, false) }
        out.append(("shelf-tile-empty", AnyView(shelf), false))
        out.append(("shelf-cards", shelfCards(), true))
        out.append(("memory-graph", memoryGraph(selection: nil), true))
        out.append(("memory-graph-selected", memoryGraph(selection: "t-pr"), true))
        out.append(("memory-graph-empty", memoryGraph(MemoryGraph(nodes: [], edges: []), selection: nil), true))
        return out
    }

    /// The Memory tab's Graph mode at the panel's content size, with a sample week.
    private static func memoryGraph(_ graph: MemoryGraph = MemoryGraphSample.week, selection: String?) -> AnyView {
        let model = MemoryGraphModel(preset: graph)
        let view = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Spacer(minLength: 4)
                MemoryGraphControls(model: model)
            }
            MemoryGraphView(model: model, fadeIn: false, initialSelection: selection)
        }
        return AnyView(view.frame(width: 536, height: 270))
    }

    private static func approvalCard() -> AnyView {
        let now = Date()
        // A zero-width space: the card shows "Contains hidden characters".
        let summary = "rm -rf ./build\u{200B} && npm test -- --grep \"panel\""
        let approval = Approval(id: "render", sessionKey: "s", agent: "claude-code", agentName: "Claude Code",
                                project: "platynotch", tool: "Bash", summary: summary,
                                createdAt: now, expiresAt: now.addingTimeInterval(300))
        let card = ApprovalCard(approval: approval, session: nil, canAnswer: true, phase: nil,
                                arming: ApprovalArming(), onDecide: { _ in }, onOpenTerminal: { _ in })
        return AnyView(card.frame(width: 396))
    }

    private static func games() -> [(String, AnyView)] {
        let w = GamesWidget.inert()
        var out: [(String, AnyView)] = []
        for kind in [GameKind.snake, .twenty48] {
            w.host.select(kind)
            let board = GameBoard(session: w.host.session, date: Date(), decorate: false)
            out.append(("game-\(kind.rawValue)", AnyView(board)))
        }
        return out
    }

    private static func shelfCards() -> AnyView {
        let shelf = ShelfWidget.inert()
        let now = Date()
        let text = ShelfItem(kind: .text("Meeting notes for Thursday"), addedAt: now)
        let link = ShelfItem(kind: .url(URL(string: "https://example.com/report")!), addedAt: now, pinned: true)
        let row = HStack(spacing: 6) {
            ShelfCard(shelf: shelf, item: text, missing: false, selected: false)
            ShelfCard(shelf: shelf, item: link, missing: false, selected: true)
        }
        return AnyView(row)
    }
}
