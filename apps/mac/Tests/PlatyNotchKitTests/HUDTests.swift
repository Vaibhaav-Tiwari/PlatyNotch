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
                      ready: Set<UInt32> = [1], anyDisplay: Bool = false) -> MediaKeyGate {
        MediaKeyGate(active: active, available: available, readyDisplays: ready, readyOnAnyDisplay: anyDisplay)
    }

    private let up = MediaKeyEvent(kind: .volumeUp, isDown: true, isRepeat: false)
    private let upRelease = MediaKeyEvent(kind: .volumeUp, isDown: false, isRepeat: false)

    func testSwallowsWhenOurHUDShowsOnTheTargetDisplay() {
        var g = gate()
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 1),
                       .swallow(MediaKeyAction(kind: .volumeUp, fine: false)))
        XCTAssertEqual(g.decide(upRelease, modifiers: MediaKeyModifiers(), display: 1), .swallow(nil))
    }

    func testFineActionWithOptionShift() {
        var g = gate()
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(option: true, shift: true), display: 1),
                       .swallow(MediaKeyAction(kind: .volumeUp, fine: true)))
    }

    func testPassesThroughWhenTheTargetDisplayHasNoHUD() {
        var g = gate(ready: [1])
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 2), .passThrough,
                       "the HUD would show on another display or none: the system HUD shows")
        g = gate(ready: [])
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 1), .passThrough,
                       "full screen, ringing or a drag: our HUD would not show")
        g = gate(ready: [], anyDisplay: true)
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 7).swallows, true)
    }

    func testPassesThroughWhenInactive() {
        var g = gate(active: false)
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 1), .passThrough,
                       "no permission, no tap or widget off: never swallow")
    }

    func testPassesThroughUnavailableControls() {
        var g = gate(available: [.volumeUp, .volumeDown])
        let brighter = MediaKeyEvent(kind: .brightnessUp, isDown: true, isRepeat: false)
        XCTAssertEqual(g.decide(brighter, modifiers: MediaKeyModifiers(), display: 1), .passThrough)
        let mute = MediaKeyEvent(kind: .mute, isDown: true, isRepeat: false)
        XCTAssertEqual(g.decide(mute, modifiers: MediaKeyModifiers(), display: 1), .passThrough,
                       "a device without a settable mute keeps the system's handling")
    }

    func testPassesThroughOtherKeysAndOptionAlone() {
        var g = gate()
        XCTAssertEqual(g.decide(nil, modifiers: MediaKeyModifiers(), display: 1), .passThrough)
        let play = MediaKeyEvent(kind: .other, isDown: true, isRepeat: false)
        XCTAssertEqual(g.decide(play, modifiers: MediaKeyModifiers(), display: 1), .passThrough)
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(option: true, shift: false), display: 1),
                       .passThrough, "⌥ alone opens the Sound settings: the system's job")
    }

    func testKeyUpFollowsItsKeyDown() {
        var g = gate(ready: [])
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 1), .passThrough)
        g.readyDisplays = [1]
        XCTAssertEqual(g.decide(upRelease, modifiers: MediaKeyModifiers(), display: 1), .passThrough,
                       "the system saw the key-down, so it gets the key-up")
        XCTAssertEqual(g.decide(up, modifiers: MediaKeyModifiers(), display: 1).swallows, true)
        g.active = false
        XCTAssertEqual(g.decide(upRelease, modifiers: MediaKeyModifiers(), display: 1), .passThrough,
                       "inactive passes everything, even a key-up whose down we took")
        XCTAssertEqual(g.decide(upRelease, modifiers: MediaKeyModifiers(), display: 1), .passThrough)
    }

    func testRepeatsAreSteps() {
        var g = gate()
        let held = MediaKeyEvent(kind: .volumeDown, isDown: true, isRepeat: true)
        XCTAssertEqual(g.decide(held, modifiers: MediaKeyModifiers(), display: 1),
                       .swallow(MediaKeyAction(kind: .volumeDown, fine: false)))
    }

    // MARK: - Whether a HUD would show (the panel side of the gate)

    func testHUDWouldShow() {
        var m = PanelStateMachine()
        XCTAssertTrue(m.hudWouldShow, "compact: the HUD grows out of the pill")
        m.handle(.approvalsChanged(count: 1))
        XCTAssertTrue(m.hudWouldShow, "approval: a 2 pt indicator, still ours")
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
        XCTAssertTrue(m.hudWouldShow, "open panel: indicator")
        XCTAssertNil(m.hud, "asking never sets a HUD")
        XCTAssertTrue(PanelStateMachine(minimal: true).hudWouldShow, "hidden in Minimal mode: the HUD still shows")
    }
}
