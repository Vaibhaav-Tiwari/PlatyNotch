import PlatyNotchKit
import SwiftUI

/// The Memory tool (Island spec 4): a search field (↩ searches) with its results, the open
/// loops (resolve, dismiss), and "Open graph". No loops: "No open loops. Platy's keeping watch."
struct MemoryTool: View {
    let search: AnyView
    let loops: [Loop]
    let onOpenGraph: () -> Void
    var onResolve: (Loop) -> Void = { _ in }
    var onDismiss: (Loop) -> Void = { _ in }

    static let empty = "No open loops. Platy's keeping watch."

    static func texts(_ loops: [Loop]) -> [String] {
        loops.isEmpty ? [empty] : loops.map(\.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            search
                .frame(height: 150)
            HStack {
                Text(verbatim: "OPEN LOOPS")
                    .font(DS.font(TypeScale.caption)).tracking(0.6).foregroundStyle(DS.tertiary)
                Spacer()
                Button(action: onOpenGraph) {
                    HStack(spacing: 4) {
                        Text("Open graph")
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                    .font(DS.font(TypeScale.caption).weight(.medium))
                    .foregroundStyle(DS.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            if loops.isEmpty {
                ToolEmptyLine(text: Self.empty)
            } else {
                ToolList(items: loops) { loop in
                    ToolRow(symbol: "circle.dashed", icon: nil, title: loop.title, detail: loop.kind,
                            selected: false) {
                        HStack(spacing: 4) {
                            iconButton("checkmark", "Done") { onResolve(loop) }
                            iconButton("xmark", "Dismiss") { onDismiss(loop) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DS.secondary)
                .frame(width: 24, height: 24)
                .background(DS.raised, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// The Memory tool wired to the app: search on top, the loops from the store (less those
/// just answered), and the graph one click away (‹ Search returns).
struct MemoryToolHost: View {
    let store: AppStore
    let memory: MemoryServices
    let actions: LoopActions?
    @State private var graph = false

    var body: some View {
        if graph {
            VStack(alignment: .leading, spacing: 6) {
                Button { graph = false } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Search")
                    }
                    .font(DS.font(TypeScale.caption).weight(.medium))
                    .foregroundStyle(DS.secondary)
                }
                .buttonStyle(.plain)
                MemoryTab(store: store, memory: memory, mode: .graph, modePicker: false)
            }
        } else {
            let hidden: Set<String> = actions?.hidden ?? []
            MemoryTool(search: AnyView(MemoryTab(store: store, memory: memory, mode: .search, modePicker: false)),
                       loops: LoopsFormat.open(store.loops).filter { !hidden.contains($0.id) },
                       onOpenGraph: { graph = true },
                       onResolve: { actions?.set($0, .resolved) },
                       onDismiss: { actions?.set($0, .dismissed) })
        }
    }
}
