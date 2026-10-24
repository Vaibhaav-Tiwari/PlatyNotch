import AppKit
import Foundation
import Observation
import PlatyNotchKit
import SwiftUI

/// What one panel's games tab reports about itself.
public struct GameSurface: Equatable, Sendable {
    /// The panel is expanded and on screen (not hidden or suppressed).
    public var shown: Bool
    /// A full-screen app covers the panel's display.
    public var fullScreen: Bool
    /// The panel is the key window and the board is its first responder (after a click).
    public var focused: Bool

    public init(shown: Bool, fullScreen: Bool, focused: Bool) {
        self.shown = shown
        self.fullScreen = fullScreen
        self.focused = focused
    }
}

/// A new best score (Task 13: Platy celebrates). `at` tells repeats apart.
public struct GameCelebration: Equatable, Sendable {
    public var result: GameResult
    public var at: Date
}

/// The games' controller, shared by every display's panel (one `GameSession`, so a game
/// left on one display is still there on another). Feeds the session its blockers, keys
/// and frames, saves high scores and reports new bests.
///
/// Pausing (Task 10 ruling): any pending approval, anything ringing, the panel collapsed
/// or the tab gone, keyboard focus lost (the panel resigned key, or the board is not first
/// responder), full screen. Blockers are re-read before every key and every frame, so no
/// key and no frame reaches a game while an approval is pending even before the change
/// notification lands; while a game plays, the store and the rings are observed so the
/// board shows "Paused" at once (2048 has no frames). Resuming needs Space (after a click
/// when focus was lost) and continues from the exact state.
///
/// Nothing runs until a game is opened and played: no timer, no observation, no frames.
@MainActor @Observable
public final class GameHost {
    /// Set directly only by tests.
    public internal(set) var session: GameSession
    /// The latest new best; observed by Task 13.
    public private(set) var celebration: GameCelebration?
    /// Told about every new best (after `celebration` is set).
    @ObservationIgnored public var onNewBest: ((GameResult) -> Void)?

    /// Pending approvals (the widget reads `AppStore.approvals` through this).
    @ObservationIgnored var approvals: () -> Int = { 0 }
    /// Whether anything rings (`PanelSurfaces.ringing`).
    @ObservationIgnored var ringing: () -> Bool = { false }
    /// nil: inert (smoke runs), scores are never saved.
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var surfaces: [UUID: GameSurface] = [:]
    /// The tab the user last clicked into: only its state counts.
    @ObservationIgnored private(set) var owner: UUID?
    @ObservationIgnored private var tracking = false
    @ObservationIgnored private var now: () -> Date = Date.init

    public init(defaults: UserDefaults?, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.defaults = defaults
        let scores = defaults.map { HighScores.load(from: $0) } ?? HighScores()
        session = GameSession(seed: seed, scores: scores)
    }

    public var blockers: GameBlockers { session.blockers }
    /// Frames are wanted (the tab's TimelineView is paused otherwise).
    public var isRunning: Bool { session.isRunning }
    /// Read live (not from the last refresh), so the tab hides the board the moment an
    /// approval arrives.
    public var approvalPending: Bool { approvals() > 0 }

    // MARK: - From the games tab

    /// A tab's state changed (or it appeared).
    public func surfaceChanged(_ id: UUID, _ surface: GameSurface) {
        guard surfaces[id] != surface else { return }
        surfaces[id] = surface
        if surface.focused { owner = id }
        refresh()
    }

    /// The tab left the screen (panel collapsed, another tab, panel rebuilt).
    public func surfaceGone(_ id: UUID) {
        surfaces[id] = nil
        if owner == id { owner = nil }
        refresh()
    }

    /// A key from the board of tab `id`; false lets it go on to the panel.
    public func handle(_ key: GameKey, from id: UUID) -> Bool {
        guard id == owner else { return false }
        refresh()
        var next = session
        let taken = next.key(key)
        commit(next)
        return taken
    }

    /// A frame (the TimelineView's date, seconds) from tab `id`. Only the owner's frames
    /// count: two displays showing the tab must not drive the clock twice.
    public func frame(now time: Double, from id: UUID) {
        guard id == owner else { return }
        refresh()
        guard session.isRunning else { return }
        var next = session
        next.advance(to: time)
        commit(next)
    }

    public func select(_ kind: GameKind) {
        var next = session
        next.select(kind)
        commit(next)
    }

    public func resetScores() {
        var next = session
        next.scores = HighScores()
        commit(next)
    }

    /// The widget stopped: forget the tabs and the signals; a playing game pauses.
    func stop() {
        surfaces = [:]
        owner = nil
        refresh()
        approvals = { 0 }
        ringing = { false }
    }

    /// Re-reads every blocker and pauses a playing game if one holds.
    public func refresh() {
        var b = GameBlockers()
        b.approval = approvals() > 0
        b.ringing = ringing()
        if let owner, let s = surfaces[owner] {
            b.collapsed = !s.shown
            b.keyLost = !s.focused
            b.fullScreen = s.fullScreen
        } else {
            b.collapsed = true
            b.keyLost = true
        }
        guard b != session.blockers else { return }
        var next = session
        next.setBlockers(b)
        commit(next)
    }

    // MARK: - Private

    private func commit(_ next: GameSession) {
        guard next != session else { return }
        let before = session
        session = next
        if next.scores != before.scores, let defaults { next.scores.save(to: defaults) }
        // `newBest` is set only by a game over and cleared by the next game, so nil → set
        // is exactly one new best.
        if let best = next.newBest, before.newBest == nil {
            celebration = GameCelebration(result: best, at: now())
            onNewBest?(best)
        }
        if next.phase == .playing { track() }
    }

    /// While a game plays: an approval or a ring pauses it without waiting for a frame.
    private func track() {
        guard !tracking else { return }
        tracking = true
        withObservationTracking {
            _ = approvals()
            _ = ringing()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.tracking = false
                self.refresh()
                if self.session.phase == .playing { self.track() }
            }
        }
    }
}

extension GameKey {
    /// The game key for a key-down, if any (never with ⌘, ⌃ or ⌥ held).
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var mods: Set<GameKey.Modifier> = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { mods.insert(.shift) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        self.init(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, modifiers: mods,
                  isRepeat: event.isARepeat)
    }
}

/// The board's keyboard: an AppKit view that becomes first responder only when clicked
/// (never on hover, never when the panel becomes key by itself). Unhandled keys go up the
/// responder chain (Escape reaches the panel). It never handles key equivalents, so the
/// approval cards' ⌘↩ / ⌘⌫ always reach them.
final class GameKeyView: NSView {
    var onKey: (GameKey) -> Bool = { _ in false }
    var onFocus: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    /// Set by a click; cleared when the board loses first responder.
    private(set) var armed = false
    private var observers: [NSObjectProtocol] = []

    override var acceptsFirstResponder: Bool { armed }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        armed = true
        onClick()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        reportFocus()
    }

    override func becomeFirstResponder() -> Bool {
        guard armed else { return false }
        return true
    }

    override func resignFirstResponder() -> Bool {
        armed = false
        // After AppKit has moved first responder on.
        Task { @MainActor [weak self] in self?.reportFocus() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if let key = GameKey(event: event), onKey(key) { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guard let window else {
            armed = false
            onFocus(false)
            return
        }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportFocus() }
        })
        observers.append(nc.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowResignedKey() }
        })
    }

    /// The board takes keys: armed, first responder, in the key window.
    var hasFocus: Bool {
        armed && window?.isKeyWindow == true && window?.firstResponder === self
    }

    func reportFocus() { onFocus(hasFocus) }

    /// Key loss disarms the board: when the panel becomes key again (hover, another click
    /// on the panel) the board does not take keys until it is clicked itself.
    func windowResignedKey() {
        armed = false
        if let window, window.firstResponder === self { window.makeFirstResponder(nil) }
        reportFocus()
    }

    func dismantle() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        armed = false
        onFocus(false)
    }
}

/// SwiftUI wrapper for `GameKeyView`, laid over the board.
struct GameKeyCatcher: NSViewRepresentable {
    var onKey: (GameKey) -> Bool
    var onFocus: (Bool) -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> GameKeyView {
        let v = GameKeyView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: GameKeyView, context: Context) {
        v.onKey = onKey
        v.onFocus = onFocus
        v.onClick = onClick
    }

    static func dismantleNSView(_ v: GameKeyView, coordinator: ()) { v.dismantle() }
}
