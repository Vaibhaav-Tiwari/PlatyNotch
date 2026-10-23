import AppKit
import PlatyNotchKit
import SwiftUI

/// What the panel's SwiftUI content reads; written by `NotchController`.
@MainActor @Observable
final class PanelViewModel {
    var mode: PanelMode = .compact
    var visible = false
    var layout: PanelLayout?
    var selectedTab = BuiltinTab.agents
    /// Which approval cards have been on screen long enough to be answered (this window).
    var arming = ApprovalArming()
    /// Toggles expanded / collapsed (the state machine's `.click`).
    var onClick: () -> Void = {}
}

/// Places the mode's content inside the fixed-size panel window.
struct PanelRootView: View {
    let model: PanelViewModel
    let store: AppStore
    let responder: ApprovalResponder
    let extraTabs: [PanelTab]
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layout = model.layout {
                let r = PanelLayout.localRect(layout.contentRect(for: model.mode), in: layout.windowFrame)
                content(layout)
                    .frame(width: r.width, height: r.height)
                    .background(Theme.surface)
                    .clipShape(Theme.panelShape(hasNotch: layout.hasNotch))
                    .offset(x: r.minX, y: r.minY)
                    .opacity(model.visible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.25), value: model.mode)
        .animation(.easeOut(duration: 0.15), value: model.visible)
    }

    @ViewBuilder private func content(_ layout: PanelLayout) -> some View {
        // Open content starts below the camera housing on a notch.
        let top: CGFloat = layout.hasNotch ? layout.anchor.height + 4 : 10
        switch model.mode {
        case .hidden:
            Color.clear
        case .compact:
            CompactPill(dots: PillDots(sessions: store.sessions), approvalCount: store.approvals.count,
                        connection: store.connection, hasNotch: layout.hasNotch,
                        notchWidth: layout.hasNotch ? layout.anchor.width : 0)
                .contentShape(Rectangle())
                .onTapGesture { model.onClick() }
        case .peek(.approval):
            ApprovalPeek(store: store, responder: responder, arming: model.arming, onExpand: model.onClick,
                         onDecide: decide, onOpenTerminal: onOpenTerminal)
                .padding(EdgeInsets(top: top, leading: 12, bottom: 10, trailing: 12))
        case .peek(.notice):
            Group {
                if let notice = store.notices.last { NoticeToast(notice: notice) } else { Color.clear }
            }
            .padding(EdgeInsets(top: top, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { model.onClick() }
        case .expanded:
            ExpandedPanel(store: store, responder: responder, arming: model.arming, extraTabs: extraTabs,
                          selectedTab: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 }),
                          onCollapse: model.onClick, onDecide: decide, onOpenTerminal: onOpenTerminal)
                .padding(EdgeInsets(top: top, leading: 12, bottom: 10, trailing: 12))
        }
    }
}

extension PanelRootView {
    /// Every Allow / Deny goes through here: auto-repeat keys and double-clicks are
    /// dropped, a card not yet armed shows "Look first…", and the shared responder
    /// refuses expired, in-flight or reconnecting answers.
    func decide(_ approval: Approval, _ behavior: ApprovalBehavior) {
        guard DecisionInput.accepts(NSApp.currentEvent) else { return }
        let now = Date()
        guard model.arming.attempt(approval.id, at: now) else { return }
        responder.decide(approval, behavior, now: now, canAnswer: store.canAnswerApprovals)
    }
}

/// The approval peek: the oldest approval in full; the next one as a compact row whose
/// "Open" expands the panel (answered there). The header and "More" also expand.
struct ApprovalPeek: View {
    let store: AppStore
    let responder: ApprovalResponder
    let arming: ApprovalArming
    let onExpand: () -> Void
    let onDecide: (Approval, ApprovalBehavior) -> Void
    let onOpenTerminal: (Session) -> Void

    var body: some View {
        let ordered = ApprovalFormat.ordered(store.approvals)
        VStack(alignment: .leading, spacing: 4) {
            if let first = ordered.first {
                ApprovalCard(approval: first,
                             session: store.sessions.first { $0.key == first.sessionKey },
                             canAnswer: store.canAnswerApprovals,
                             phase: responder.phase(for: first.id),
                             arming: arming,
                             maxLines: 6,
                             shortcuts: true,
                             onExpand: onExpand,
                             onDecide: { onDecide(first, $0) },
                             onOpenTerminal: onOpenTerminal)
            }
            if ordered.count > 1 {
                ApprovalRow(approval: ordered[1], more: ordered.count - 2, onOpen: onExpand)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
