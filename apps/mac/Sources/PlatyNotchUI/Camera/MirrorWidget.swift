import AppKit
import AVFoundation
import Observation
import PlatyNotchKit
import SwiftUI

/// The camera mirror (v0.2 power feature, R17): a tile in the Today tab whose preview
/// shows the camera, flipped like a mirror.
///
/// Privacy: off by default. The camera turns on only after a click inside the tile
/// ("Show Mirror"), and turns off at the first of: Hide, the tile leaving the screen (the
/// panel collapses or another tab is chosen), the panel's content hiding, screen lock,
/// display sleep, system sleep, a switch to another user, the camera failing, or the widget
/// stopping (turned off, or quit). Showing it again needs another click; nothing restarts
/// it by itself. Frames go only to the on-screen preview layer: none is read, kept, saved or
/// sent. The camera prompt appears only from the tile's button, and the camera never
/// starts unless macOS already reports access (so starting it can never prompt).
///
/// Rebuilds: a working grant is stamped with this build (`GrantStamp`, key
/// `MirrorWidget.cameraGrantKey`). When access is missing but was granted to another build,
/// the tile says "Turn On Again" and asks from that button.
///
/// Cost: with the mirror not showing, nothing runs (no session, observers or timers).
@MainActor @Observable
final class MirrorWidget: NotchWidget {
    static let widgetID = "mirror"
    /// Where this build's camera grant is stamped (`GrantStamp`).
    static let cameraGrantKey = "camera.grant"

    let id = MirrorWidget.widgetID
    let title = "Mirror"
    let systemImage = "person.crop.square"
    let defaultEnabled = false
    let category = WidgetCategory.power

    /// The camera runs (for `owner`'s tile).
    private(set) var live = false
    private(set) var auth: CameraAuth = .notDetermined
    private(set) var history: GrantHistory = .never
    private(set) var noCamera = false
    /// Waiting for the user to answer the camera prompt.
    private(set) var asking = false
    /// Why the last showing ended (tests, VoiceOver).
    private(set) var lastStop: MirrorStopReason?
    /// The tile the mirror shows in (one per display's panel can exist).
    private(set) var owner: UUID?

    @ObservationIgnored private let access: CameraAccess
    @ObservationIgnored private let grant: GrantStamp
    @ObservationIgnored private let makeFeed: @MainActor () -> CameraFeed
    @ObservationIgnored private let signals: MirrorStopSignals
    @ObservationIgnored private var feed: CameraFeed?
    @ObservationIgnored private(set) var running = false
    /// Tiles on screen. The token is held weakly: a tile whose view went away without
    /// `onDisappear` (its panel was torn down) no longer counts.
    @ObservationIgnored private var tiles: [UUID: TileEntry] = [:]

    private struct TileEntry {
        weak var token: MirrorTileToken?
        var visible: Bool
        var alive: Bool { token != nil }
    }

    init(access: CameraAccess = .system,
         grant: GrantStamp = CodeIdentity.stamp(key: MirrorWidget.cameraGrantKey),
         feed: @escaping @MainActor () -> CameraFeed = { SystemCameraFeed() },
         signals: MirrorStopSignals = SystemMirrorSignals()) {
        self.access = access
        self.grant = grant
        makeFeed = feed
        self.signals = signals
    }

    /// Never touches the camera, never prompts, saves nothing (smoke runs).
    static func inert() -> MirrorWidget {
        MirrorWidget(access: CameraAccess(status: { .notDetermined }, request: { false }),
                     grant: GrantStamp(key: MirrorWidget.cameraGrantKey, defaults: UserDefaults(suiteName: "dev.platynotch.inert")!,
                                       identity: { "inert" }),
                     feed: { InertCameraFeed() }, signals: InertMirrorSignals())
    }

    var tileState: MirrorTileState {
        MirrorTileState.decide(auth: auth, history: history, live: live, noCamera: noCamera)
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        running = true
        history = grant.history
        // The feature is on: it may use the camera only on a grant made to this build. A
        // stamp from another build is cleared; `history` keeps "Turn On Again" for the tile.
        _ = grant.launchCheck(wasOn: true)
        readAuth()
    }

    func stop() {
        end(.widgetOff)
        running = false
        asking = false
    }

    // MARK: - Tile events

    /// A tile appeared; `visible`: the panel's content shows.
    func tileAppeared(_ tile: MirrorTileToken, visible: Bool) {
        tiles = tiles.filter { $0.value.alive }
        tiles[tile.id] = TileEntry(token: tile, visible: visible)
        // A live mirror whose tile went without `onDisappear` (a rebuilt panel): stop it.
        if live, let owner, tiles[owner]?.alive != true { end(.collapsed) }
        if running { readAuth() }
    }

    /// The app rebuilt every panel (displays or appearance changed): the owner's tile is
    /// gone, whether or not it said so.
    func panelsRebuilt() {
        tiles = [:]
        end(.displaysChanged)
    }

    /// The tile left the screen (the panel collapsed, or another tab).
    func tileDisappeared(_ tile: MirrorTileToken) {
        tiles[tile.id] = nil
        if owner == tile.id { end(.collapsed) }
    }

    /// The panel's content around `tile` was hidden or shown again.
    func tileVisibility(_ tile: MirrorTileToken, visible: Bool) {
        guard tiles[tile.id] != nil else { return }
        tiles[tile.id]?.visible = visible
        if !visible, owner == tile.id { end(.panelHidden) }
    }

    /// `tile` is on screen with the panel's content showing.
    private func shows(_ tile: MirrorTileToken) -> Bool {
        guard let e = tiles[tile.id] else { return false }
        return e.alive && e.visible
    }

    /// The tile's button: shows the mirror, or hides it while live. Asks for the camera
    /// first when macOS never asked (the only place the prompt can appear).
    func buttonClicked(_ tile: MirrorTileToken) async {
        if live { end(.userHid); return }   // Hide works from any tile
        guard running, !asking, shows(tile) else { return }
        readAuth()
        if auth == .notDetermined {
            asking = true
            _ = await access.request()
            asking = false
            readAuth()
        }
        guard auth == .authorized else { return }
        // The answer may have come after the panel closed: never start unseen.
        guard running, !live, shows(tile) else { return }
        begin(in: tile.id)
    }

    func openCameraSettings() { Permissions.open(.camera) }

    // MARK: - Camera

    private func begin(in tile: UUID) {
        let feed = self.feed ?? makeFeed()
        self.feed = feed
        guard feed.start() else {
            noCamera = true
            return
        }
        noCamera = false
        feed.onLost = { [weak self] in self?.end(.cameraLost) }
        live = true
        owner = tile
        lastStop = nil
        grant.note()
        history = .thisBuild
        signals.begin { [weak self] reason in self?.end(reason) }
    }

    private func end(_ reason: MirrorStopReason) {
        guard live else { return }
        feed?.onLost = nil
        feed?.stop()
        feed = nil   // the next showing gets a new session
        signals.end()
        live = false
        owner = nil
        lastStop = reason
    }

    private func readAuth() {
        let a = Self.cameraAuth(access.status())
        if a != auth { auth = a }
        if a == .authorized, history != .thisBuild { grant.note(); history = .thisBuild }
    }

    nonisolated static func cameraAuth(_ status: AVAuthorizationStatus) -> CameraAuth {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// The live preview's session (nil for fakes and while not live).
    var session: AVCaptureSession? { live ? feed?.session : nil }

    var kind: WidgetKind { [.live, .tool] }

    /// The camera mirror is on: a minor live item (Ruling 4), so it is never forgotten.
    var liveActivities: [LiveActivity] {
        guard live else { return [] }
        return [LiveActivity(id: "mirror:on", widgetID: id, priority: LivePriority.panelActivity,
                             glyph: .symbol("camera.fill"), tint: .accent, accessibilityLabel: "Camera mirror on",
                             title: "Mirror", subtitle: "Camera on")]
    }

    /// "Mirror · Camera on" (the preview stays in its tool): no primary control.
    func heroView() -> AnyView? {
        AnyView(TopActivityHero(activities: { [weak self] in self?.liveActivities ?? [] }, action: { _ in nil }))
    }

    func tileView() -> AnyView { AnyView(MirrorTileView(widget: self)) }

    func settingsView() -> AnyView? { AnyView(MirrorSettingsView()) }
}

/// The Today tile: the preview while live, else the button and what it will do.
struct MirrorTileView: View {
    let widget: MirrorWidget
    @State private var token = MirrorTileToken()
    @Environment(\.panelTicking) private var shown
    @Environment(\.inPanelTool) private var inTool

    var body: some View {
        Group {
            if inTool { tool } else { tile }
        }
        .onAppear { widget.tileAppeared(token, visible: shown) }
        .onDisappear { widget.tileDisappeared(token) }
        .onChange(of: shown) { widget.tileVisibility(token, visible: shown) }
    }

    /// Full-panel: the preview fills the room, else what the mirror needs, centred.
    @ViewBuilder private var tool: some View {
        let state = widget.tileState
        if state == .live, widget.owner == token.id {
            VStack(spacing: Space.s) {
                MirrorPreview(session: widget.session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                HStack {
                    Text(verbatim: state.message)
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    button(state)
                }
            }
        } else if state == .live {
            ToolEmptyState(systemImage: "person.crop.square", title: "Mirror is on another display",
                           detail: "Only one panel shows the camera at a time.")
        } else {
            let tile = token
            let denied: Bool = { if case .denied = state { return true } else { return false } }()
            let widget = self.widget
            let show: () -> Void = { Task { @MainActor in await widget.buttonClicked(tile) } }
            let settings: () -> Void = { widget.openCameraSettings() }
            let action: (title: String, run: () -> Void)?
                = state.buttonTitle.map { ($0, show) } ?? (denied ? ("Open Settings", settings) : nil)
            ToolEmptyState(systemImage: "person.crop.square", title: "Check your camera before a call",
                           detail: state.message, action: action)
                .disabled(widget.asking)
        }
    }

    private var tile: some View {
        let state = widget.tileState
        return VStack(alignment: .leading, spacing: 6) {
            if state == .live, widget.owner == token.id {
                MirrorPreview(session: widget.session)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.inner(outer: Radius.card, padding: 6), style: .continuous))
            } else if state == .live {
                Label("The mirror shows on another display.", systemImage: "person.crop.square")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if state != .live {
                    Image(systemName: "person.crop.square").font(.system(size: 18)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                Text(verbatim: state.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                button(state)
            }
        }
        .padding(6)
        .dsCard()
    }

    @ViewBuilder
    private func button(_ state: MirrorTileState) -> some View {
        if let title = state.buttonTitle {
            let tile = token
            Button(title) { Task { await widget.buttonClicked(tile) } }
                .controlSize(.small)
                .disabled(widget.asking)   // Hide works from any tile
        } else if case .denied = state {
            Button("Open Settings") { widget.openCameraSettings() }
                .controlSize(.small)
        }
    }
}

/// Settings › Widgets › Mirror.
struct MirrorSettingsView: View {
    var body: some View {
        SettingsNote("""
        Click Show Mirror in the Today tab to see your camera. It turns off when you hide it, \
        close the panel, lock the screen or the display sleeps. macOS asks for the camera the \
        first time you click. Nothing is recorded, saved or sent.
        """)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One tile view's identity, held by the view (`@State`) and weakly by the widget.
@MainActor
final class MirrorTileToken {
    let id = UUID()
}

/// Never touches a camera (smoke runs).
@MainActor
final class InertCameraFeed: CameraFeed {
    var session: AVCaptureSession? { nil }
    var onLost: (@MainActor () -> Void)?
    func start() -> Bool { false }
    func stop() {}
}

/// Installs nothing (smoke runs).
@MainActor
final class InertMirrorSignals: MirrorStopSignals {
    func begin(_ onStop: @escaping @MainActor (MirrorStopReason) -> Void) {}
    func end() {}
}
