import Observation
import PlatyNotchKit
import SwiftUI

/// `memory.graph` for the Memory tab's Graph view. It asks only when the view is shown
/// (or the range changes, or Refresh is clicked), never in the background.
@MainActor @Observable
public final class MemoryGraphModel {
    static let timeout: Duration = .seconds(10)

    enum Phase: Equatable {
        case idle, loading
        case loaded(MemoryGraph)
        case memoryOff
        case failed(String)
    }

    var range: MemoryGraphFormat.Range = .week {
        didSet { if range != oldValue { refresh() } }
    }
    private(set) var phase: Phase = .idle
    /// Requests sent (tests check nothing is asked while hidden).
    private(set) var requests = 0

    @ObservationIgnored private let request: (@Sendable (Envelope) async throws -> Envelope)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Layouts of `cachedGraph` by rounded aspect (at most `cacheLimit`).
    @ObservationIgnored private var cachedGraph: MemoryGraph?
    @ObservationIgnored private(set) var cached: [Double: GraphLayout] = [:]
    static let cacheLimit = 4

    init(request: @escaping @Sendable (Envelope) async throws -> Envelope) {
        self.request = request
    }

    public convenience init(client: CoreClient) {
        self.init(request: { try await client.request($0, timeout: MemoryGraphModel.timeout) })
    }

    /// A fixed graph that never asks the core (renders, previews).
    init(preset graph: MemoryGraph, range: MemoryGraphFormat.Range = .week) {
        request = nil
        self.range = range
        phase = .loaded(MemoryGraphFormat.drawable(graph))
    }

    func refresh() {
        guard let request else { return }
        task?.cancel()
        let range = self.range
        requests += 1
        if case .loaded = phase {} else { phase = .loading }
        task = Task { [weak self] in
            let next: Phase
            do {
                switch MemoryGraphFormat.parse(try await request(try MemoryGraphFormat.envelope(range: range))) {
                case .graph(let g): next = .loaded(g)
                case .memoryOff: next = .memoryOff
                case .failed(let message): next = .failed(message)
                }
            } catch CoreClientError.notConnected {
                next = .failed("Not connected to the core.")
            } catch CoreClientError.timeout {
                next = .failed("The core did not answer. Try again.")
            } catch {
                guard !Task.isCancelled else { return }
                next = .failed("The graph failed to load. Try again.")
            }
            guard !Task.isCancelled else { return }
            self?.phase = next
        }
    }

    /// The layout for `graph` in a view of this aspect, computed once per graph and
    /// shape (hover and selection redraw without moving anything).
    func layout(_ graph: MemoryGraph, aspect: Double) -> GraphLayout {
        let rounded = (aspect * 10).rounded() / 10
        if cachedGraph != graph {
            cachedGraph = graph
            cached = [:]
        }
        if let l = cached[rounded] { return l }
        if cached.count >= Self.cacheLimit { cached = [:] }
        let l = GraphLayout.compute(graph, aspect: rounded)
        cached[rounded] = l
        return l
    }
}

/// Range picker and Refresh, shown in the Memory tab's top row in Graph mode.
struct MemoryGraphControls: View {
    @Bindable var model: MemoryGraphModel

    var body: some View {
        HStack(spacing: 6) {
            Picker("Range", selection: $model.range) {
                ForEach(MemoryGraphFormat.Range.allCases) { r in
                    Text(verbatim: r.title).tag(r).accessibilityLabel(Text(verbatim: r.spoken))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.small)
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Refresh the graph")
                .accessibilityLabel("Refresh the graph")
        }
    }
}

/// The memory graph: apps, threads, sites and open loops as shapes, linked; hover or
/// click a node for its label and links. Laid out once per graph, then static.
struct MemoryGraphView: View {
    let model: MemoryGraphModel
    var onOpenSettings: () -> Void = {}
    /// Renders: no fade, and optionally a node already selected.
    var fadeIn = true
    var initialSelection: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { model.refresh() }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .memoryOff:
            VStack(spacing: 6) {
                Image(systemName: "brain").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Memory is off").font(.system(size: 12, weight: .medium))
                Button("Open Memory Settings") { onOpenSettings() }.controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.system(size: 11))
                .foregroundStyle(Theme.color(.attention))
        case .loaded(let graph):
            if graph.nodes.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 18)).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(verbatim: "Nothing captured in the \(model.range.spoken.lowercased()).")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Apps, pages, documents and open loops show here as you work.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MemoryGraphBody(model: model, graph: graph, fadeIn: fadeIn, selected: initialSelection)
            }
        }
    }
}

/// Canvas, legend and the detail line for a loaded, non-empty graph.
private struct MemoryGraphBody: View {
    let model: MemoryGraphModel
    let graph: MemoryGraph
    @State private var hovered: String?
    @State private var selected: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var shown: Bool

    init(model: MemoryGraphModel, graph: MemoryGraph, fadeIn: Bool, selected: String?) {
        self.model = model
        self.graph = graph
        _shown = State(initialValue: !fadeIn)
        _selected = State(initialValue: selected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                canvas(size: geo.size)
            }
            .background(Theme.card.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(shown ? 1 : 0)
            .onAppear {
                // One short fade when the graph arrives; nothing moves after that.
                guard !shown else { return }
                if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.2)) { shown = true } }
            }
            MemoryGraphLegend(kinds: kindsShown)
            detailLine
        }
        .onChange(of: graph) { _, _ in hovered = nil; selected = nil }
    }

    private var kindsShown: [GraphNodeKind] {
        let present = Set(graph.nodes.compactMap(\.nodeKind))
        return GraphNodeKind.allCases.filter { $0 != .topic || present.contains(.topic) }
    }

    private var focus: String? { hovered ?? selected }

    @ViewBuilder private var detailLine: some View {
        if let id = focus, let node = graph.nodes.first(where: { $0.id == id }) {
            HStack(spacing: 4) {
                Text(verbatim: MemoryGraphFormat.label(node))
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(verbatim: MemoryGraphFormat.detail(node, in: graph))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        } else {
            Text("Hover or click a shape to see what it links to.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func canvas(size: CGSize) -> some View {
        let width = Double(size.width)
        let height = Double(max(size.height, 1))
        let layout = model.layout(graph, aspect: width / height)
        let order = graph.nodes.map(\.id)
        let scene = GraphScene(graph: graph, layout: layout, width: width, height: height, focus: focus,
                               labelBackground: Theme.surface(scheme).opacity(0.85))
        return Canvas { ctx, _ in scene.draw(in: &ctx) }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    // Written only on a change: every write redraws the canvas.
                    let hit = layout.nearest(x: Double(p.x), y: Double(p.y), width: width, height: height,
                                             within: 12, order: order)
                    if hit != hovered { hovered = hit }
                case .ended:
                    if hovered != nil { hovered = nil }
                }
            }
            .onTapGesture(coordinateSpace: .local) { p in
                let hit = layout.nearest(x: Double(p.x), y: Double(p.y), width: width, height: height,
                                         within: 12, order: order)
                selected = hit == selected ? nil : hit
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: "Memory graph, \(model.range.spoken), \(graph.nodes.count) items"))
            .accessibilityChildren { MemoryGraphAccessibleList(graph: graph, selected: $selected) }
    }
}

/// What VoiceOver reads instead of the drawing: every node, heaviest first, with its
/// kind and number of connections; activating one selects it, and the selected row
/// reads its links as its value. (Moving between nodes with the keyboard alone is a
/// follow-up.)
private struct MemoryGraphAccessibleList: View {
    let graph: MemoryGraph
    @Binding var selected: String?

    var body: some View {
        VStack {
            ForEach(MemoryGraphFormat.accessibleRows(graph), id: \.id) { row in
                let isSelected = row.id == selected
                Text(verbatim: row.label)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityValue(Text(verbatim: isSelected ? value(row.id) : ""))
                    .accessibilityAction { selected = row.id }
            }
        }
    }

    private func value(_ id: String) -> String {
        guard let node = graph.nodes.first(where: { $0.id == id }) else { return "" }
        return MemoryGraphFormat.detail(node, in: graph)
    }
}

/// One frame of the graph: plain values, drawn by the Canvas.
struct GraphScene {
    let graph: MemoryGraph
    let layout: GraphLayout
    let width: Double
    let height: Double
    let focus: String?
    /// Behind the focused node's label, so it reads over lines and shapes.
    let labelBackground: Color

    private var near: Set<String> {
        guard let focus else { return [] }
        var s: Set<String> = [focus]
        for e in graph.edges where e.from == focus || e.to == focus { s.insert(e.from); s.insert(e.to) }
        return s
    }

    func draw(in ctx: inout GraphicsContext) {
        let near = self.near
        let maxWeight = graph.nodes.map(\.weight).max() ?? 1
        for e in graph.edges { drawEdge(e, near: near, in: &ctx) }
        for n in graph.nodes.reversed() { drawNode(n, maxWeight: maxWeight, near: near, in: &ctx) }   // heaviest on top
        for n in graph.nodes { drawLabel(n, maxWeight: maxWeight, near: near, in: &ctx) }
    }

    private func cg(_ id: String) -> CGPoint? {
        guard let p = layout.point(id, width: width, height: height) else { return nil }
        return CGPoint(x: p.x, y: p.y)
    }

    private func drawEdge(_ e: GraphEdge, near: Set<String>, in ctx: inout GraphicsContext) {
        guard let a = cg(e.from), let b = cg(e.to) else { return }
        var path = Path()
        path.move(to: a)
        path.addLine(to: b)
        let lit = focus != nil && (e.from == focus || e.to == focus)
        let alpha: Double = lit ? 0.7 : (focus == nil ? 0.28 : 0.1)
        let style = StrokeStyle(lineWidth: lit ? 1.5 : 1, dash: e.kind == "together" ? [3, 3] : [])
        ctx.stroke(path, with: .color(Color.secondary.opacity(alpha)), style: style)
    }

    private func drawNode(_ n: GraphNode, maxWeight: Double, near: Set<String>, in ctx: inout GraphicsContext) {
        guard let kind = n.nodeKind, let c = cg(n.id) else { return }
        let r = CGFloat(MemoryGraphFormat.radius(weight: n.weight, maxWeight: maxWeight))
        let path = GraphShapes.path(kind, center: c, radius: r)
        let dim = focus != nil && !near.contains(n.id)
        ctx.fill(path, with: .color(GraphShapes.color(kind).opacity(dim ? 0.25 : 0.9)))
        if n.id == focus {
            ctx.stroke(path, with: .color(Color.primary), lineWidth: 1.5)
        }
    }

    /// Apps are always labelled; anything else when it or a neighbour has focus.
    private func drawLabel(_ n: GraphNode, maxWeight: Double, near: Set<String>, in ctx: inout GraphicsContext) {
        guard let kind = n.nodeKind, let c = cg(n.id) else { return }
        let show = n.id == focus || (kind == .app && (focus == nil || near.contains(n.id)))
        guard show else { return }
        let r = CGFloat(MemoryGraphFormat.radius(weight: n.weight, maxWeight: maxWeight))
        let label = MemoryGraphFormat.shortLabel(n, max: 28)
        let text = Text(verbatim: label).font(.system(size: 10, weight: n.id == focus ? .semibold : .regular))
            .foregroundStyle(.primary)
        let resolved = ctx.resolve(text)
        let at = CGPoint(x: c.x, y: c.y + r + 2)
        if n.id == focus {
            let size = resolved.measure(in: CGSize(width: 240, height: 20))
            let box = CGRect(x: at.x - size.width / 2 - 3, y: at.y - 1, width: size.width + 6, height: size.height + 2)
            ctx.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(labelBackground))
        }
        ctx.draw(resolved, at: at, anchor: .top)
    }
}

/// Each kind's shape and colour: the shape alone tells them apart for anyone who
/// cannot see the colours.
enum GraphShapes {
    static func color(_ kind: GraphNodeKind) -> Color {
        switch kind {
        case .app: Color(nsColor: .systemBlue)
        case .thread: Color(nsColor: .systemTeal)
        case .site: Color(nsColor: .systemGreen)
        case .loop: Color(nsColor: .systemOrange)
        case .topic: Color(nsColor: .systemPurple)
        }
    }

    static func path(_ kind: GraphNodeKind, center c: CGPoint, radius r: CGFloat) -> Path {
        let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        switch kind {
        case .app:
            return Path(roundedRect: box.insetBy(dx: r * 0.1, dy: r * 0.1), cornerRadius: r * 0.35)
        case .thread:
            return Path(ellipseIn: box)
        case .site:
            return polygon(c, r * 1.15, sides: 4, rotation: -Double.pi / 2)
        case .loop:
            return polygon(c, r * 1.2, sides: 3, rotation: -Double.pi / 2)
        case .topic:
            return polygon(c, r, sides: 6, rotation: 0)
        }
    }

    private static func polygon(_ c: CGPoint, _ r: CGFloat, sides: Int, rotation: Double) -> Path {
        var p = Path()
        for i in 0..<sides {
            let a = rotation + Double(i) * 2 * Double.pi / Double(sides)
            let pt = CGPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// Which shape is which.
struct MemoryGraphLegend: View {
    let kinds: [GraphNodeKind]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 3) {
                    Canvas { ctx, size in
                        let c = CGPoint(x: size.width / 2, y: size.height / 2)
                        ctx.fill(GraphShapes.path(kind, center: c, radius: 4), with: .color(GraphShapes.color(kind)))
                    }
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                    Text(verbatim: MemoryGraphFormat.kindName(kind))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
