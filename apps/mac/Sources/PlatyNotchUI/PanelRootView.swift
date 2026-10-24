import AppKit
import PlatyNotchKit
import SwiftUI

/// What the panel's SwiftUI content reads; written by `NotchController`.
@MainActor @Observable
final class PanelViewModel {
    var mode: PanelMode = .compact
    var visible = false
    /// A full-screen app covers this panel's display (games pause).
    var fullScreen = false
    var layout: PanelLayout?
    var selectedTab = BuiltinTab.agents
    /// Which approval cards have been on screen long enough to be answered (this window).
    var arming = ApprovalArming()
    /// Toggles expanded / collapsed (the state machine's `.click`).
    var onClick: () -> Void = {}
    /// The current HUD (drawn as its own surface in `.peek(.hud)`).
    var hud: HUDState?
    /// A HUD drawn as a thin line inside the approval peek or the open panel.
    var hudIndicator: HUDState?
    /// Something ringing under an approval or the open panel: the header chip.
    var ringingChip: RingingItem?
    /// Stops a ringing alarm or timer (the chip; a card no running widget draws any more).
    var onStopRinging: (String) -> Void = { _ in }
    /// Settings › Appearance, clamped (live side, theme, spring).
    var appearance: AppearanceSettings = AppearanceSettings()
}

/// Places the mode's content inside the fixed-size panel window.
struct PanelRootView: View {
    let model: PanelViewModel
    let store: AppStore
    let responder: ApprovalResponder
    let today: TodayServices
    let widgets: WidgetRegistry
    let memory: MemoryServices
    let extraTabs: [PanelTab]
    let onOpenTerminal: (Session) -> Void
    /// The system's scheme (Appearance › Theme: System follows it).
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The blur new content settles out of after a mode change (Appearance › spring blur).
    @State private var morphBlur: CGFloat = 0

    var body: some View {
        let scheme = Theme.scheme(model.appearance.theme, system: systemScheme, mode: model.mode,
                                  hasNotch: model.layout?.hasNotch ?? false)
        ZStack(alignment: .topLeading) {
            if let layout = model.layout {
                let r = PanelLayout.localRect(layout.contentRect(for: model.mode), in: layout.windowFrame)
                content(layout)
                    .blur(radius: morphBlur)
                    .frame(width: r.width, height: r.height)
                    .overlay(alignment: .topLeading) { chip(layout) }
                    .background(Theme.surface(scheme))
                    .clipShape(Theme.panelShape(hasNotch: layout.hasNotch))
                    .offset(x: r.minX, y: r.minY)
                    .opacity(model.visible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, scheme)
        // Pill timelines (countdown, music bars) tick only while the panel is really shown,
        // not while hidden or suppressed over full screen.
        .environment(\.panelTicking, model.visible)
        .environment(\.musicVisualiser, today.visualiser)
        .environment(\.platyMood, model.appearance.showPlaty ? platyMood : nil)
        // The games tab pauses unless the panel is open, on screen and not over full screen.
        .environment(\.gamePanel, GamePanelState(expanded: model.mode == .expanded, visible: model.visible,
                                                 fullScreen: model.fullScreen))
        .animation(modeAnimation, value: model.mode)
        .animation(.easeOut(duration: 0.15), value: model.visible)
        .onChange(of: model.mode) { settleBlur() }
    }

    /// Platy's mood from the store, music, focus and the timed inputs.
    private var platyMood: PlatyMood {
        // Typed locals keep the call cheap to type-check.
        let sessions: [Session] = store.sessions
        let approvals: Int = store.approvals.count
        let music: Bool = today.nowPlaying.isPlaying
        let focus: Bool = today.focus.focusActive
        return today.platy.mood(sessions: sessions, approvals: approvals, musicPlaying: music, focusActive: focus)
    }

    /// Appearance › spring (clamped); a short ease with Reduce Motion.
    private var modeAnimation: Animation {
        if reduceMotion { return .easeOut(duration: 0.15) }
        let spring = model.appearance.spring
        return .spring(response: spring.response, dampingFraction: spring.dampingFraction)
    }

    /// New content starts blurred and settles sharp with the spring. Runs once per mode
    /// change (never while resting), and not at all with Reduce Motion or a 0 blur.
    private func settleBlur() {
        let blur = CGFloat(model.appearance.spring.blur)
        guard !reduceMotion, blur > 0 else { return }
        var start = Transaction()
        start.disablesAnimations = true
        withTransaction(start) { morphBlur = blur }
        withAnimation(modeAnimation) { morphBlur = 0 }
    }

    @ViewBuilder private func content(_ layout: PanelLayout) -> some View {
        // Open content starts below the camera housing on a notch.
        // (below the header strip for the approval peek and open panel without a notch).
        let top = layout.contentInset(for: model.mode)
        switch model.mode {
        case .hidden:
            Color.clear
        case .compact:
            let live = LiveArbiter.pick(widgets.liveActivities, now: Date())
            CompactPill(dots: PillDots(sessions: store.sessions), approvalCount: store.approvals.count,
                        connection: store.connection, hasNotch: layout.hasNotch,
                        notchWidth: layout.hasNotch ? layout.anchor.width : 0,
                        primary: live.primary, bubble: live.bubble,
                        liveSide: model.appearance.liveSide, earWidth: layout.liveEarWidth,
                        platy: model.appearance.showPlaty ? platyMood : nil)
                .contentShape(Rectangle())
                .onTapGesture { model.onClick() }
        case .peek(.approval):
            ApprovalPeek(store: store, responder: responder, arming: model.arming, onExpand: model.onClick,
                         onDecide: decide, onOpenTerminal: onOpenTerminal)
                .padding(EdgeInsets(top: top, leading: 12, bottom: 10, trailing: 12))
                .overlay(alignment: .bottom) { hudIndicator }
        case .peek(.notice):
            Group {
                if let notice = store.notices.last { NoticeToast(notice: notice) } else { Color.clear }
            }
            .padding(EdgeInsets(top: top, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { model.onClick() }
        case .expanded:
            ExpandedPanel(store: store, responder: responder, arming: model.arming, today: today,
                          widgets: widgets, memory: memory, extraTabs: extraTabs,
                          selectedTab: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0 }),
                          onCollapse: model.onClick, onDecide: decide, onOpenTerminal: onOpenTerminal)
                .padding(EdgeInsets(top: top, leading: 12, bottom: 10, trailing: 12))
                .overlay(alignment: .bottom) { hudIndicator }
        case .peek(.widget(let id)):
            // A widget's peek (nudge, plug-in, AirPods). Never takes keyboard focus.
            (widgets.peekView(id: id) ?? AnyView(Color.clear))
                .padding(EdgeInsets(top: top, leading: 14, bottom: 10, trailing: 14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .peek(.ringing(let id)):
            (widgets.peekView(id: id) ?? AnyView(RingingFallback(id: id, onStop: { model.onStopRinging(id) })))
                .padding(EdgeInsets(top: top, leading: 14, bottom: 10, trailing: 14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .peek(.hud(let kind)):
            let state = model.hud ?? HUDState(kind: kind, level: 0, until: .distantPast)
            (widgets.hudView(kind: kind, level: state.level) ?? AnyView(HUDBar(state: state)))
                .padding(EdgeInsets(top: layout.hasNotch ? layout.anchor.height + 2 : 4, leading: 14,
                                    bottom: 6, trailing: 14))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        case .peek(.drop):
            (widgets.dropZoneView() ?? AnyView(DropZonePlaceholder()))
                .padding(EdgeInsets(top: top, leading: 12, bottom: 10, trailing: 12))
        }
    }

    /// The ringing chip at its fixed place (`PanelLayout.ringingChipRect`): beside the
    /// camera or in the header strip, never over or moving an approval card.
    @ViewBuilder private func chip(_ layout: PanelLayout) -> some View {
        if let item = model.ringingChip, let rect = layout.ringingChipRect(for: model.mode) {
            let content = layout.contentRect(for: model.mode)
            RingingChip(item: item, onStop: { model.onStopRinging(item.id) })
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX - content.minX, y: content.maxY - rect.maxY)
        }
    }

    @ViewBuilder private var hudIndicator: some View {
        if let h = model.hudIndicator {
            HUDIndicator(state: h).padding(.bottom, 3).allowsHitTesting(false)
        }
    }
}

extension PanelRootView {
    /// Every Allow / Deny goes through here: auto-repeat keys and double-clicks are
    /// dropped, a card not yet armed (or no longer in the slot it was armed in) shows
    /// "Look first…", and the shared responder
    /// refuses expired, in-flight or reconnecting answers.
    func decide(_ approval: Approval, _ behavior: ApprovalBehavior) {
        guard DecisionInput.accepts(NSApp.currentEvent) else { return }
        let now = Date()
        let slot = ApprovalFormat.ordered(store.approvals).firstIndex { $0.id == approval.id }
        guard model.arming.attempt(approval.id, slot: slot, at: now) else { return }
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
