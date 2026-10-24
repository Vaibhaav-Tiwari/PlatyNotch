import Foundation
import XCTest
import PlatyNotchKit   // not @testable: every type the UI uses must be public (C6)

/// Volume, brightness and keyboard-backlight HUDs (Plan 3b Task 4; C18 vectors).
final class HUDTests: XCTestCase {

    // MARK: - Decoding NX_SYSDEFINED media keys (C18)

    private func decode(_ data1: Int, subtype: Int = MediaKeyEvent.systemDefinedSubtype) -> MediaKeyEvent? {
        MediaKeyEvent.decode(subtype: subtype, data1: data1)
    }

    func testDecodeVolumeUpDown() {
        XCTAssertEqual(decode(0x0000_0A00), MediaKeyEvent(kind: .volumeUp, isDown: true, isRepeat: false))
        XCTAssertEqual(decode(0x0000_0B00), MediaKeyEvent(kind: .volumeUp, isDown: false, isRepeat: false))
        XCTAssertEqual(decode(0x0001_0A00), MediaKeyEvent(kind: .volumeDown, isDown: true, isRepeat: false))
    }

    func testDecodeMute() {
        XCTAssertEqual(decode(0x0007_0A00), MediaKeyEvent(kind: .mute, isDown: true, isRepeat: false))
        XCTAssertEqual(decode(0x0007_0B00), MediaKeyEvent(kind: .mute, isDown: false, isRepeat: false))
    }

    func testDecodeBrightnessAndBacklight() {
        XCTAssertEqual(decode(0x0002_0A00)?.kind, .brightnessUp)
        XCTAssertEqual(decode(0x0003_0A00)?.kind, .brightnessDown)
        XCTAssertEqual(decode(0x0015_0A00)?.kind, .backlightUp)
        XCTAssertEqual(decode(0x0016_0A00)?.kind, .backlightDown)
    }

    func testDecodeRepeat() {
        XCTAssertEqual(decode(0x0000_0A01), MediaKeyEvent(kind: .volumeUp, isDown: true, isRepeat: true))
        XCTAssertEqual(decode(0x0001_0A01)?.isRepeat, true)
    }

    func testDecodeUnknown() {
        // Key code 10 (0x0A, Num Lock: the plan's old "volume up" vector) and 23
        // (illumination toggle) are outside the table.
        XCTAssertEqual(decode(0x000A_0A00), MediaKeyEvent(kind: .other, isDown: true, isRepeat: false))
        XCTAssertEqual(decode(0x0017_0A00)?.kind, .other)
        XCTAssertEqual(decode(0x0010_0B00)?.kind, .other)   // play/pause: the music player's
    }

    func testDecodeRejectsOtherSubtypesAndStates() {
        XCTAssertNil(decode(0x0000_0A00, subtype: 7))   // aux mouse buttons
        XCTAssertNil(decode(0x0000_0C00))               // neither down (0x0A) nor up (0x0B)
        XCTAssertNil(decode(0))
    }

    func testKindsMapToHUDs() {
        XCTAssertEqual(MediaKeyKind.volumeUp.hud, .volume)
        XCTAssertEqual(MediaKeyKind.mute.hud, .volume)
        XCTAssertEqual(MediaKeyKind.brightnessDown.hud, .brightness)
        XCTAssertEqual(MediaKeyKind.backlightUp.hud, .keyboardBacklight)
        XCTAssertNil(MediaKeyKind.other.hud)
    }

    // MARK: - Modifiers

    func testModifiers() {
        let option: UInt64 = 0x0008_0000, shift: UInt64 = 0x0002_0000, command: UInt64 = 0x0010_0000
        XCTAssertEqual(MediaKeyModifiers(flags: option | shift), MediaKeyModifiers(option: true, shift: true))
        XCTAssertTrue(MediaKeyModifiers(flags: option | shift).fine)
        XCTAssertFalse(MediaKeyModifiers(flags: option | shift).opensSystemSettings)
        XCTAssertTrue(MediaKeyModifiers(flags: option).opensSystemSettings)
        XCTAssertFalse(MediaKeyModifiers(flags: shift).fine)
        XCTAssertEqual(MediaKeyModifiers(flags: command), MediaKeyModifiers())
    }

    // MARK: - Level steps

    func testLevelStepClamps() {
        XCTAssertEqual(LevelStep.next(1, up: true, fine: false), 1)
        XCTAssertEqual(LevelStep.next(0, up: false, fine: false), 0)
        XCTAssertEqual(LevelStep.next(0.98, up: true, fine: false), 1)
        XCTAssertEqual(LevelStep.next(0.01, up: false, fine: true), 0)
        XCTAssertEqual(LevelStep.next(0.02, up: false, fine: true), 0.015625)
        XCTAssertEqual(LevelStep.next(1.7, up: true, fine: false), 1)
        XCTAssertEqual(LevelStep.next(-0.3, up: false, fine: false), 0)
        XCTAssertEqual(LevelStep.next(-0.3, up: true, fine: false), 0.0625)
        XCTAssertEqual(LevelStep.next(.nan, up: true, fine: false), 0.0625)
    }

    func testCoarseSteps() {
        XCTAssertEqual(LevelStep.next(0.5, up: true, fine: false), 0.5625)
        XCTAssertEqual(LevelStep.next(0.5, up: false, fine: false), 0.4375)
        // Off the grid: to the next grid point in that direction.
        XCTAssertEqual(LevelStep.next(0.53, up: true, fine: false), 0.5625)
        XCTAssertEqual(LevelStep.next(0.53, up: false, fine: false), 0.5)
        // A hair off the grid (as read back from CoreAudio) counts as on it.
        XCTAssertEqual(LevelStep.next(0.49999, up: true, fine: false), 0.5625)
        XCTAssertEqual(LevelStep.next(0.50001, up: false, fine: false), 0.4375)
        var level: Float = 0
        var presses = 0
        while level < 1 { level = LevelStep.next(level, up: true, fine: false); presses += 1 }
        XCTAssertEqual(presses, LevelStep.coarseSteps)
    }

    func testFineSteps() {
        XCTAssertEqual(LevelStep.next(0.5, up: true, fine: true), 0.515625)
        XCTAssertEqual(LevelStep.next(0.5, up: false, fine: true), 0.484375)
        var level: Float = 1
        var presses = 0
        while level > 0 { level = LevelStep.next(level, up: false, fine: true); presses += 1 }
        XCTAssertEqual(presses, LevelStep.fineSteps)
        XCTAssertEqual(LevelStep.fineSteps, LevelStep.coarseSteps * 4)   // ⌥⇧: quarter steps
    }

    // MARK: - Volume and mute

    func testVolumeUpUnmutesAndSteps() {
        let s = VolumeChange.apply(.volumeUp, fine: false, to: VolumeChange.State(volume: 0.25, muted: true))
        XCTAssertEqual(s, VolumeChange.State(volume: 0.3125, muted: false))
        XCTAssertEqual(s.shownLevel, 0.3125)
    }

    func testMuteTogglesAndShowsZero() {
        let muted = VolumeChange.apply(.mute, fine: false, to: VolumeChange.State(volume: 0.5, muted: false))
        XCTAssertEqual(muted, VolumeChange.State(volume: 0.5, muted: true))
        XCTAssertEqual(muted.shownLevel, 0)
        XCTAssertEqual(VolumeChange.apply(.mute, fine: false, to: muted), VolumeChange.State(volume: 0.5, muted: false))
    }

    func testVolumeDownKeepsMuteAndClamps() {
        let s = VolumeChange.apply(.volumeDown, fine: true, to: VolumeChange.State(volume: 0.01, muted: true))
        XCTAssertEqual(s, VolumeChange.State(volume: 0, muted: true))
        XCTAssertEqual(VolumeChange.apply(.brightnessUp, fine: false, to: s), s)   // not a volume key
    }

    // MARK: - Swallow only when our HUD shows (the gate the event tap asks)

    private func gate(active: Bool = true, available: Set<MediaKeyKind> = MediaKeyKind.handled,
                      ready: Set<UInt32> = [1], anyDisplay: Bool = false, brightness: UInt32? = 1) -> MediaKeyGate {
        MediaKeyGate(active: active, available: available, readyDisplays: ready, readyOnAnyDisplay: anyDisplay,
                     brightnessDisplay: brightness)
    }

    private let none = MediaKeyModifiers()
    private func down(_ kind: MediaKeyKind, repeat r: Bool = false) -> MediaKeyEvent {
        MediaKeyEvent(kind: kind, isDown: true, isRepeat: r)
    }
    private func release(_ kind: MediaKeyKind) -> MediaKeyEvent { MediaKeyEvent(kind: kind, isDown: false, isRepeat: false) }

    /// Decides at `now` and, like the main thread keeping up, marks the hand-off as run.
    private func decideServed(_ g: inout MediaKeyGate, _ e: MediaKeyEvent?, modifiers: MediaKeyModifiers = MediaKeyModifiers(),
                              display: UInt32 = 1, now: TimeInterval = 0) -> MediaKeyDecision {
        let d = g.decide(e, modifiers: modifiers, display: display, now: now)
        if case .swallow(_?) = d { g.handOffRan() }
        return d
    }

    func testSwallowsWhenOurHUDShowsOnTheTargetDisplay() {
        var g = gate()
        XCTAssertEqual(g.decide(down(.volumeUp), modifiers: none, display: 1, now: 0),
                       .swallow(MediaKeyAction(kind: .volumeUp, fine: false)))
        XCTAssertEqual(g.pendingHandOffs, 1, "a taken key-down is a hand-off to main")
        XCTAssertEqual(g.decide(release(.volumeUp), modifiers: none, display: 1, now: 0), .swallow(nil))
        XCTAssertEqual(g.pendingHandOffs, 1, "a key-up hands nothing off")
        g.handOffRan()
        XCTAssertEqual(g.pendingHandOffs, 0)
    }

    func testFineActionWithOptionShift() {
        var g = gate()
        XCTAssertEqual(decideServed(&g, down(.volumeUp), modifiers: MediaKeyModifiers(option: true, shift: true)),
                       .swallow(MediaKeyAction(kind: .volumeUp, fine: true)))
    }

    func testPassesThroughWhenTheTargetDisplayHasNoHUD() {
        var g = gate(ready: [1])
        XCTAssertEqual(decideServed(&g, down(.volumeUp), display: 2), .passThrough,
                       "the HUD would show on another display or none: the system HUD shows")
        g = gate(ready: [])
        XCTAssertEqual(decideServed(&g, down(.volumeUp)), .passThrough,
                       "full screen, approval, open panel, ringing or a drag: no full HUD")
        g = gate(ready: [], anyDisplay: true)
        XCTAssertTrue(decideServed(&g, down(.volumeUp), display: 7).swallows)
    }

    func testPassesThroughWhenInactive() {
        var g = gate(active: false)
        XCTAssertEqual(decideServed(&g, down(.volumeUp)), .passThrough,
                       "no permission, no tap or widget off: never swallow")
    }

    func testPassesThroughUnavailableControls() {
        var g = gate(available: [.volumeUp, .volumeDown])
        XCTAssertEqual(decideServed(&g, down(.brightnessUp)), .passThrough)
        XCTAssertEqual(decideServed(&g, down(.mute)), .passThrough,
                       "a device without a settable mute keeps the system's handling")
    }

    func testBrightnessOnlyForTheDisplayWeControl() {
        var g = gate(ready: [1, 2], brightness: 1)
        XCTAssertTrue(decideServed(&g, down(.brightnessUp), display: 1).swallows)
        XCTAssertEqual(decideServed(&g, down(.brightnessUp), display: 2), .passThrough,
                       "cursor on an external display: its brightness is the system's")
        XCTAssertTrue(decideServed(&g, down(.volumeUp), display: 2).swallows, "volume is not per display")
        g = gate(brightness: nil)
        XCTAssertEqual(decideServed(&g, down(.brightnessDown)), .passThrough)
    }

    func testPassesThroughOtherKeysAndOptionAlone() {
        var g = gate()
        XCTAssertEqual(decideServed(&g, nil), .passThrough)
        XCTAssertEqual(decideServed(&g, down(.other)), .passThrough)
        XCTAssertEqual(decideServed(&g, down(.volumeUp), modifiers: MediaKeyModifiers(option: true, shift: false)),
                       .passThrough, "⌥ alone opens the Sound settings: the system's job")
    }

    func testAKeyStaysWithWhoeverGotItsFirstDown() {
        var g = gate(ready: [])
        XCTAssertEqual(decideServed(&g, down(.volumeUp)), .passThrough)
        g.readyDisplays = [1]
        XCTAssertEqual(decideServed(&g, down(.volumeUp, repeat: true)), .passThrough,
                       "the system started this key: its repeats stay the system's")
        XCTAssertEqual(decideServed(&g, release(.volumeUp)), .passThrough, "and its key-up")
        XCTAssertTrue(decideServed(&g, down(.volumeUp)).swallows, "a new press is decided afresh")
        XCTAssertEqual(decideServed(&g, down(.volumeUp, repeat: true)),
                       .swallow(MediaKeyAction(kind: .volumeUp, fine: false)), "repeats of our key step")
        g.readyDisplays = []
        XCTAssertEqual(decideServed(&g, down(.volumeUp, repeat: true)), .passThrough,
                       "a repeat passes as soon as our HUD could not show")
        XCTAssertEqual(decideServed(&g, release(.volumeUp)), .passThrough)
    }

    func testInactivePassesEvenTheKeyUpOfOurKey() {
        var g = gate()
        XCTAssertTrue(decideServed(&g, down(.volumeDown)).swallows)
        g.active = false
        XCTAssertEqual(decideServed(&g, release(.volumeDown)), .passThrough)
        g.active = true
        XCTAssertEqual(decideServed(&g, release(.volumeDown)), .passThrough, "state was cleared")
    }

    func testMuteRepeatsDoNothing() {
        var g = gate()
        XCTAssertEqual(decideServed(&g, down(.mute)), .swallow(MediaKeyAction(kind: .mute, fine: false)))
        XCTAssertEqual(g.decide(down(.mute, repeat: true), modifiers: none, display: 1, now: 0), .swallow(nil),
                       "holding mute toggles once (repeat consumed, no action)")
        XCTAssertEqual(g.pendingHandOffs, 0)
        XCTAssertEqual(decideServed(&g, release(.mute)), .swallow(nil))
        var passed = gate(ready: [])
        XCTAssertEqual(decideServed(&passed, down(.mute)), .passThrough)
        XCTAssertEqual(decideServed(&passed, down(.mute, repeat: true)), .passThrough)
    }

    // MARK: - Liveness: keys go to the system while main is behind

    func testPassesThroughWhileAHandOffIsOverdue() {
        var g = gate()
        XCTAssertTrue(g.decide(down(.volumeUp), modifiers: none, display: 1, now: 10).swallows)
        XCTAssertEqual(g.decide(release(.volumeUp), modifiers: none, display: 1, now: 10.1), .swallow(nil))
        XCTAssertFalse(g.mainIsLate(now: 10.25), "at the deadline: still in time")
        XCTAssertTrue(g.decide(down(.volumeUp), modifiers: none, display: 1, now: 10.2).swallows,
                       "main a little behind (200 ms): still ours")
        XCTAssertEqual(g.pendingHandOffs, 2)
        XCTAssertTrue(g.mainIsLate(now: 10.26))
        XCTAssertEqual(g.decide(down(.volumeDown), modifiers: none, display: 1, now: 10.3), .passThrough,
                       "oldest hand-off 300 ms old: main is hung, the system takes the key")
        XCTAssertEqual(g.pendingHandOffs, 2, "a passed key adds no hand-off")
        g.handOffRan()   // main recovers: the one sent at 10.0 runs
        XCTAssertTrue(g.decide(down(.volumeDown), modifiers: none, display: 1, now: 10.4).swallows,
                      "the oldest left (sent at 10.2) is 200 ms old: in time")
        XCTAssertTrue(g.mainIsLate(now: 10.46), "and overdue 60 ms later if main stalls again")
        g.handOffRan()
        g.handOffRan()
        XCTAssertFalse(g.mainIsLate(now: 99))
        XCTAssertTrue(g.decide(down(.volumeDown), modifiers: none, display: 1, now: 99).swallows, "caught up")
    }

    func testHandOffRanWithNothingPendingIsHarmless() {
        var g = gate()
        g.handOffRan()
        XCTAssertEqual(g.pendingHandOffs, 0)
        XCTAssertFalse(g.mainIsLate(now: 1_000))
    }

    // MARK: - Whether a full HUD would show (the panel side of the gate)

    func testHUDWouldShow() {
        var m = PanelStateMachine()
        XCTAssertTrue(m.hudWouldShow, "compact: the HUD grows out of the pill")
        m.handle(.approvalsChanged(count: 1))
        XCTAssertFalse(m.hudWouldShow, "approval: only the 2 pt indicator, which is not feedback enough to take the key")
        m.handle(.approvalsChanged(count: 0))
        m.handle(.ringStarted(id: "alarm"))
        XCTAssertFalse(m.hudWouldShow, "under a ringing card the HUD is dropped")
        m.handle(.ringStopped(id: "alarm"))
        m.handle(.dragBegan)
        XCTAssertFalse(m.hudWouldShow)
        m.handle(.dragEnded)
        m.setFullScreen(true)
        XCTAssertFalse(m.hudWouldShow, "full screen: suppressed, the system HUD shows")
        m.setFullScreen(false)
        m.handle(.click)
        XCTAssertFalse(m.hudWouldShow, "open panel: indicator only")
        m.handle(.click)
        XCTAssertTrue(m.hudWouldShow)
        XCTAssertNil(m.hud, "asking never sets a HUD")
        XCTAssertTrue(PanelStateMachine(minimal: true).hudWouldShow, "hidden in Minimal mode: the HUD still shows")
    }
}
