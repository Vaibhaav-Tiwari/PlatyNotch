import PlatyNotchKit
import SwiftUI

/// A tab in the expanded panel. Built-in tabs come first; plugins append theirs
/// (passed to `NotchController` as `extraTabs`).
@MainActor
public struct PanelTab: Identifiable {
    public let id: String
    public let title: String
    let content: () -> AnyView

    public init<Content: View>(id: String, title: String, @ViewBuilder content: @escaping () -> Content) {
        self.id = id
        self.title = title
        self.content = { AnyView(content()) }
    }
}

enum BuiltinTab {
    static let agents = "agents"
    static let today = "today"
    static let focus = "focus"
    static let memory = "memory"
}

/// The open panel: tab bar, pending approvals (always on top), then the selected tab.
struct ExpandedPanel: View {
    let store: AppStore
    let responder: ApprovalResponder
    let arming: ApprovalArming
    let today: TodayServices
    let memory: MemoryServices
    let extraTabs: [PanelTab]
    @Binding var selectedTab: String
    let onCollapse: () -> Void
    let onDecide: (Approval, ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        let tabs = allTabs
        VStack(alignment: .leading, spacing: 8) {
            tabBar(tabs)
            if !store.approvals.isEmpty {
                approvals
                    .frame(maxHeight: 240, alignment: .top)
                    .layoutPriority(1)
            }
            (tabs.first { $0.id == selectedTab } ?? tabs[0]).content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

    /// Pending approvals, oldest first. With several, summaries are shorter (each still
    /// scrolls to its full text) so more cards fit, and the list scrolls.
    @ViewBuilder private var approvals: some View {
        let count = store.approvals.count
        let list = ApprovalList(approvals: store.approvals, sessions: store.sessions,
                                canAnswer: store.canAnswerApprovals, responder: responder, arming: arming,
                                maxLines: count > 1 ? 5 : ApprovalFormat.maxSummaryLines,
                                onDecide: onDecide, onOpenTerminal: onOpenTerminal)
        VStack(alignment: .leading, spacing: 4) {
            if count > 1 {
                Text("\(count) approvals waiting · oldest first")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.color(.attention))
            }
            ViewThatFits(in: .vertical) {
                list
                ScrollView(.vertical) { list }
            }
        }
    }

    private var allTabs: [PanelTab] {
        let store = self.store
        let open = onOpenTerminal
        let today = self.today
        let memory = self.memory
        return [
            PanelTab(id: BuiltinTab.agents, title: "Agents") {
                AgentsTab(sessions: store.sessions, usage: store.usage, onOpenTerminal: open)
            },
            PanelTab(id: BuiltinTab.today, title: "Today") {
                TodayTab(store: store, today: today)
            },
            PanelTab(id: BuiltinTab.focus, title: "Focus") {
                FocusTab(focus: today.focus)
            },
            PanelTab(id: BuiltinTab.memory, title: "Memory") {
                MemoryTab(store: store, memory: memory)
            },
        ] + extraTabs
    }

    private func tabBar(_ tabs: [PanelTab]) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab.id == (tabs.contains { $0.id == selectedTab } ? selectedTab : tabs[0].id)
                Button { selectedTab = tab.id } label: {
                    Text(verbatim: tab.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(selected ? Theme.card : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(tab.title) tab")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 4)
            if store.connection != .connected {
                Label(store.connection == .connecting ? "Connecting…" : "Reconnecting…",
                      systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.color(.attention))
            }
            Button(action: onCollapse) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close panel")
        }
    }
}
