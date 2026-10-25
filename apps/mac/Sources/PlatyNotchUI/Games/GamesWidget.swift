import Foundation
import Observation
import PlatyNotchKit
import SwiftUI

/// Snake, Tetris, 2048, Flappy and Platy Chase in the expanded panel's Games tab; the Today tile picks
/// one and shows the best scores.
///
/// On by default, and does nothing until a game is opened and played: `start` only wires
/// the pause signals (pending approvals, ringing), with no timer or observer. High scores
/// are kept in `UserDefaults.standard` (`HighScores.key`), never sent anywhere.
///
/// Task 13 hook: `celebration` changes (and `onNewBest` is called) when a game ends with a
/// new best (`HighScores.record` returned true).
@MainActor @Observable
public final class GamesWidget: NotchWidget {
    nonisolated public static let widgetID = "games"
    /// The expanded panel's tab id.
    nonisolated public static let tabID = "games"

    public let id = GamesWidget.widgetID
    public let title = "Games"
    public let systemImage = "gamecontroller"
    public let defaultEnabled = true

    public let host: GameHost
    @ObservationIgnored private var openTab: () -> Void = {}

    /// Scores come from `defaults` (the app passes `.standard`, the same domain as
    /// `WidgetContext.defaults`), not from the context in `start`: the tile and Settings
    /// show the best scores before the widget starts and while it is off.
    /// `defaults: nil` keeps scores in memory only (smoke runs).
    public init(defaults: UserDefaults? = .standard) {
        host = GameHost(defaults: defaults)
    }

    /// Nothing saved (smoke runs).
    public static func inert() -> GamesWidget { GamesWidget(defaults: nil) }

    /// The latest new best (Task 13: Platy celebrates).
    public var celebration: GameCelebration? { host.celebration }

    public var onNewBest: ((GameResult) -> Void)? {
        get { host.onNewBest }
        set { host.onNewBest = newValue }
    }

    public func start(context: WidgetContext) {
        let store = context.store
        let surfaces = context.surfaces
        host.approvals = { store.approvals.count }
        host.ringing = { !surfaces.ringing.isEmpty }
        openTab = { context.openPanel(tab: GamesWidget.tabID) }
        host.refresh()
    }

    public func stop() {
        host.stop()
        openTab = {}
    }

    public var kind: WidgetKind { [.live, .tool] }

    /// Platy Chase in play: a minor live item (Ruling 4).
    public var liveActivities: [LiveActivity] {
        let session = host.session
        guard session.kind == .chase, session.phase == .playing else { return [] }
        return [LiveActivity(id: "games:chase", widgetID: id, priority: LivePriority.panelActivity,
                             glyph: .symbol("gamecontroller.fill"), tint: .accent,
                             accessibilityLabel: "Platy Chase in play", title: "Platy Chase",
                             subtitle: "Score \(session.score)")]
    }

    /// Platy Chase in play and its score: no primary control.
    public func heroView() -> AnyView? {
        AnyView(TopActivityHero(activities: { [weak self] in self?.liveActivities ?? [] }, action: { _ in nil }))
    }

    public func tileView() -> AnyView {
        AnyView(GamesTile(host: host, open: { [weak self] in self?.openTab() }))
    }

    public func settingsView() -> AnyView? { AnyView(GamesSettings(host: host)) }
}

// MARK: - Panel environment

/// What the panel tells its games tab (set by `PanelRootView`).
struct GamePanelState: Equatable {
    var expanded = false
    var visible = false
    var fullScreen = false
}

private struct GamePanelKey: EnvironmentKey {
    static let defaultValue = GamePanelState()
}

/// Switches the expanded panel's tab (set by `ExpandedPanel`; nil elsewhere).
private struct SelectPanelTabKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    var gamePanel: GamePanelState {
        get { self[GamePanelKey.self] }
        set { self[GamePanelKey.self] = newValue }
    }

    var selectPanelTab: (@MainActor (String) -> Void)? {
        get { self[SelectPanelTabKey.self] }
        set { self[SelectPanelTabKey.self] = newValue }
    }
}

// MARK: - Tile and settings

/// Today tile: one button per game (with its best) that opens it in the Games tab.
struct GamesTile: View {
    let host: GameHost
    let open: () -> Void
    @Environment(\.selectPanelTab) private var selectTab

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Games", systemImage: "gamecontroller")
                .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 6) {
                ForEach(GameKind.allCases) { kind in
                    Button { choose(kind) } label: { label(kind) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(kind.title)")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCard()
    }

    private func label(_ kind: GameKind) -> some View {
        let best = host.session.scores.best(kind.rawValue)
        return VStack(spacing: 2) {
            Text(verbatim: kind.shortTitle).font(.system(size: 11, weight: .medium))
            Text(best > 0 ? "Best \(best)" : "New")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
        .contentShape(Rectangle())
    }

    private func choose(_ kind: GameKind) {
        host.select(kind)
        if let selectTab { selectTab(GamesWidget.tabID) } else { open() }
    }
}

/// Settings › Widgets › Games: the best scores and a reset.
struct GamesSettings: View {
    let host: GameHost

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(GameKind.allCases) { kind in
                HStack {
                    Text(verbatim: kind.title)
                    Spacer()
                    Text(verbatim: "\(host.session.scores.best(kind.rawValue))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }
            Button("Reset High Scores") { host.resetScores() }
                .disabled(host.session.scores.scores.isEmpty)
            Text("Keys work after you click into a game. Games pause for approvals, alarms, full screen and when the panel closes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
