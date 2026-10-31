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
    /// Where the open panel is: Home by default, or Agents or a feature open inside Home
    /// (`NotchController.expand(tab:)` maps today's tab ids through `PanelRoute.legacy`).
    var route = PanelRoute(destination: .home)
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
    /// The open panel's Settings gear (never in the approval peek, no keyboard shortcut).
    var onOpenSettings: () -> Void = {}
    /// The Agents empty state's "Connect an agent" (Settings › Agents).
    var onConnectAgent: () -> Void = {}
    /// Settings › Appearance, clamped (live side, theme, motion).
    var appearance: AppearanceSettings = AppearanceSettings()
    /// Settings › Notifications: kinds the pill leaves out (never approvals).
    var hiddenKinds: Set<NotificationKind> = []
    /// The first run's "Try it" sample ("This is Now") in Now's deck.
    var tourSample: LiveActivity?
    /// The notice the toast shows (the one that opened it, not merely the newest).
    var toastNotice: Notice?
    /// Settings › Home (the right column), refreshed when the saved settings change.
    var homeSettings = HomeSettings()
    /// Home's natural body height while plain Home shows (the controller sizes the panel to it);
    /// nil: the panel takes its full height.
    var onBodyHeight: (CGFloat?) -> Void = { _ in }
    /// The header toggles' services (the app's one; nil in renders and tests).
    var header: HeaderServices?
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
    /// The mode before the current one: picks the open or the close spring. Updated after
    /// each change, so the body that animates a change still sees the old mode here.
    @State private var previousMode: PanelMode = .compact
    /// The open/close morph's matched geometry (spec 9).
    @Namespace private var morphSpace

    var body: some View {
        let scheme = Theme.scheme(model.appearance.theme, system: systemScheme, mode: model.mode,
                                  hasNotch: model.layout?.hasNotch ?? false)
        ZStack(alignment: .topLeading) {
            if let layout = model.layout {
                let r = PanelLayout.localRect(layout.contentRect(for: model.mode), in: layout.windowFrame)
                // One container around the mode's content: modifiers on the bare switch would
                // be copied into each branch, so a mode change cross-faded two whole panels
                // (surface and clip at their own sizes) instead of growing one.
                ZStack(alignment: .topLeading) { content(layout) }
                    .frame(width: r.width, height: r.height)
                    .overlay(alignment: .topLeading) { chip(layout) }
                    .background(alignment: .topLeading) { surface(layout, scheme: scheme, content: r) }
                    .clipShape(Theme.panelShape(hasNotch: layout.hasNotch))
                    .offset(x: r.minX, y: r.minY)
                    // Reduced motion (and Reduce Motion): each mode is its own panel, so a
                    // change cross-fades the two instead of resizing one (spec 9).
                    .id(crossFadeKey)
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
        .environment(\.morph, morphContext)
        // The games tab pauses unless the panel is open, on screen and not over full screen.
        .environment(\.gamePanel, GamePanelState(expanded: model.mode == .expanded, visible: model.visible,
                                                 fullScreen: model.fullScreen))
        .animation(modeAnimation, value: model.mode)
        .animation(.easeOut(duration: 0.15), value: model.visible)
        .onChange(of: model.mode) { _, new in
            previousMode = new
        }
    }

    /// The mode's surface, with the pure-black band level with the camera housing on a
    /// notch (`PanelLayout.notchBand`) so the open panel meets the notch seamlessly.
    @ViewBuilder private func surface(_ layout: PanelLayout, scheme: ColorScheme, content r: CGRect) -> some View {
        let approvals: Bool = !store.approvals.isEmpty
        let style: AppearanceSettings.SurfaceStyle = model.appearance.effectiveSurface(
            glassAvailable: Theme.glassAvailable, mode: model.mode, approvalsShowing: approvals)
        ZStack(alignment: .topLeading) {
            Theme.surface(scheme, mode: model.mode, hasNotch: layout.hasNotch, style: style)
            if let band = layout.notchBand(for: model.mode) {
                Color(PanelPalette.darkSurface)
                    .frame(width: band.width, height: band.height)
                    .offset(x: band.minX - r.minX, y: band.minY - r.minY)
            }
        }
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

    /// What identifies the panel container: one for every mode while it morphs, the mode
    /// itself under reduced motion (a cross-fade, no resizing).
    private var crossFadeKey: String {
        let preset: MotionPreset = model.appearance.effectiveMotion(reduceMotion: reduceMotion)
        return Morph.morphsPlaty(motion: preset) ? "panel" : model.mode.description
    }

    /// The morph (spec 9): Platy always; nil under reduced motion (cross-fades only, no morph).
    private var morphContext: MorphContext? {
        let preset: MotionPreset = model.appearance.effectiveMotion(reduceMotion: reduceMotion)
        guard Morph.morphsPlaty(motion: preset) else { return nil }
        return MorphContext(namespace: morphSpace, liveID: nil)
    }

    /// Appearance › Motion: the open or close spring of the preset (no blur in any preset);
    /// a short ease for Reduced and with Reduce Motion.
    private var modeAnimation: Animation {
        let preset: MotionPreset = model.appearance.effectiveMotion(reduceMotion: reduceMotion)
        let direction: MotionDirection = MotionDirection.between(previousMode, model.mode)
        guard let spring = preset.spring(direction) else {
            return .easeOut(duration: MotionPreset.reducedFade)
        }
        return .spring(response: spring.response, dampingFraction: spring.damping)
    }

    @ViewBuilder private func content(_ layout: PanelLayout) -> some View {
        // Open content starts below the camera housing on a notch.
        // (below the header strip for the approval peek and open panel without a notch).
        let top = layout.contentInset(for: model.mode)
        switch model.mode {
        case .hidden:
            Color.clear
        case .compact:
            let pill = PillContent(activities: widgets.liveActivities, sessions: store.sessions,
                                   approvals: store.approvals.count, hiddenKinds: model.hiddenKinds,
                                   log: today.agentActivity.log, now: Date())
            CompactPill(content: pill, connection: store.connection, hasNotch: layout.hasNotch,
                        notchWidth: layout.hasNotch ? layout.anchor.width : 0,
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
                if let notice = model.toastNotice ?? store.notices.last { NoticeToast(notice: notice) } else { Color.clear }
            }
            .padding(EdgeInsets(top: top, leading: 14, bottom: 10, trailing: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { model.onClick() }
        case .expanded:
            // Approval cards are not chrome: they show at once (arming counts from then).
            ChromeSettle {
            ExpandedPanel(store: store, responder: responder, arming: model.arming, today: today,
                          widgets: widgets, memory: memory, extraTabs: extraTabs,
                          route: Binding(get: { model.route }, set: { model.route = $0 }),
                          onCollapse: model.onClick, onOpenSettings: model.onOpenSettings,
                          header: model.header,
                          homeSettings: model.homeSettings,
                          agentsVisible: today.agentActivity.agentsVisibility.isVisible,
                          onConnectAgent: model.onConnectAgent,
                          tourSample: model.tourSample,
                          onBodyHeight: model.onBodyHeight,
                          onDecide: decide, onOpenTerminal: onOpenTerminal)
            }
            .transition(ChromeSettle<EmptyView>.transition)
                .padding(EdgeInsets(top: top, leading: Space.panelMargin, bottom: 10, trailing: Space.panelMargin))
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
        case .peek(.hover):
            // Peek on hover, open on click: the top live item alone; a click anywhere opens
            // the panel. No approval card is ever drawn here (an approval replaces it).
            ChromeSettle {
                HoverPeekView(widgets: widgets)
            }
            .transition(ChromeSettle<EmptyView>.transition)
                // 6 at the bottom: the 160 pt hero fits the 176 pt peek without a notch too.
                .padding(EdgeInsets(top: top, leading: 12, bottom: 6, trailing: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .onTapGesture { model.onClick() }
        case .peek(.drop):
            // The Home body becomes drop targets: Shelf and AirDrop in one dashed box.
            HomeView(today: today, widgets: widgets, settings: model.homeSettings, dropping: true,
                     dropHover: (widgets.widget(ShelfWidget.widgetID) as? ShelfWidget)?.dropZone)
                .padding(EdgeInsets(top: top, leading: Space.panelMargin, bottom: 10, trailing: Space.panelMargin))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
        let placement = model.visible ? ApprovalPlacement(mode: model.mode, count: store.approvals.count) : nil
        guard model.arming.attempt(approval.id, slot: slot, placement: placement, at: now) else { return }
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

    /// The oldest approval's card: today's summary (no preview: the peek's size and
    /// arming do not change), plus "Show changes" when the payload has a diff (spec 6.8).
    func firstCard() -> ApprovalCard? {
        guard let first = ApprovalFormat.ordered(store.approvals).first else { return nil }
        return ApprovalCard(approval: first,
                            session: store.sessions.first { $0.key == first.sessionKey },
                            canAnswer: store.canAnswerApprovals,
                            phase: responder.phase(for: first.id),
                            arming: arming,
                            maxLines: 6,
                            shortcuts: true,
                            onExpand: onExpand,
                            showChanges: Self.showsChanges(first),
                            onDecide: { onDecide(first, $0) },
                            onOpenTerminal: onOpenTerminal)
    }

    /// The payload carries a diff to show in the open panel (never built here).
    static func showsChanges(_ approval: Approval) -> Bool {
        ApprovalPreview.hasDiff(approval)
    }

    var body: some View {
        let ordered = ApprovalFormat.ordered(store.approvals)
        VStack(alignment: .leading, spacing: 4) {
            if let card = firstCard() { card }
            if ordered.count > 1 {
                ApprovalRow(approval: ordered[1], more: ordered.count - 2, onOpen: onExpand)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
