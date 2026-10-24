import Foundation

/// A media key the HUDs care about (`NX_KEYTYPE_*` in IOKit's ev_keymap.h).
public enum MediaKeyKind: Equatable, Hashable, Sendable {
    case volumeUp, volumeDown, mute, brightnessUp, brightnessDown, backlightUp, backlightDown, other

    /// Every kind PlatyNotch can handle itself.
    public static let handled: Set<MediaKeyKind> = [.volumeUp, .volumeDown, .mute, .brightnessUp,
                                                    .brightnessDown, .backlightUp, .backlightDown]

    /// `NX_KEYTYPE_*` → kind: 0 sound up, 1 sound down, 7 mute, 2/3 brightness, 21/22 illumination.
    public init(keyCode: Int) {
        switch keyCode {
        case 0: self = .volumeUp
        case 1: self = .volumeDown
        case 7: self = .mute
        case 2: self = .brightnessUp
        case 3: self = .brightnessDown
        case 21: self = .backlightUp
        case 22: self = .backlightDown
        default: self = .other
        }
    }

    /// The HUD this key shows; nil for `.other`.
    public var hud: HUDKind? {
        switch self {
        case .volumeUp, .volumeDown, .mute: .volume
        case .brightnessUp, .brightnessDown: .brightness
        case .backlightUp, .backlightDown: .keyboardBacklight
        case .other: nil
        }
    }

    /// Raises the level (`volumeUp`, `brightnessUp`, `backlightUp`).
    public var isUp: Bool { self == .volumeUp || self == .brightnessUp || self == .backlightUp }
}

/// One `NX_SYSDEFINED` media-key event.
public struct MediaKeyEvent: Equatable, Sendable {
    /// `NSEvent.subtype` of media keys (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`).
    public static let systemDefinedSubtype = 8
    /// `CGEventType` raw value of `NX_SYSDEFINED` (the tap's mask is `1 << 14`).
    public static let systemDefinedEventType: UInt32 = 14

    public let kind: MediaKeyKind
    public let isDown: Bool
    public let isRepeat: Bool

    public init(kind: MediaKeyKind, isDown: Bool, isRepeat: Bool) {
        self.kind = kind
        self.isDown = isDown
        self.isRepeat = isRepeat
    }

    /// `data1` layout: key code in bits 16–31, key state in bits 8–15 (0x0A down,
    /// 0x0B up), repeat in bit 0. Nil for other subtypes and states; key codes outside
    /// the table decode as `.other`.
    public static func decode(subtype: Int, data1: Int) -> MediaKeyEvent? {
        guard subtype == systemDefinedSubtype else { return nil }
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let state = (data1 & 0xFF00) >> 8
        let isDown: Bool
        switch state {
        case 0x0A: isDown = true
        case 0x0B: isDown = false
        default: return nil
        }
        return MediaKeyEvent(kind: MediaKeyKind(keyCode: keyCode), isDown: isDown, isRepeat: data1 & 0x1 != 0)
    }
}

/// The modifiers that change what a media key does.
public struct MediaKeyModifiers: Equatable, Sendable {
    /// `CGEventFlags.maskAlternate` / `.maskShift`.
    public static let optionMask: UInt64 = 0x0008_0000
    public static let shiftMask: UInt64 = 0x0002_0000

    public var option: Bool
    public var shift: Bool

    public init(option: Bool = false, shift: Bool = false) {
        self.option = option
        self.shift = shift
    }

    /// From `CGEventFlags.rawValue`.
    public init(flags: UInt64) {
        self.init(option: flags & Self.optionMask != 0, shift: flags & Self.shiftMask != 0)
    }

    /// ⌥⇧: quarter steps, as macOS does.
    public var fine: Bool { option && shift }
    /// ⌥ alone opens the Sound / Displays settings: left to the system.
    public var opensSystemSettings: Bool { option && !shift }
}

/// What to do for a swallowed key-down.
public struct MediaKeyAction: Equatable, Sendable {
    public var kind: MediaKeyKind
    public var fine: Bool

    public init(kind: MediaKeyKind, fine: Bool) {
        self.kind = kind
        self.fine = fine
    }
}

public enum MediaKeyDecision: Equatable, Sendable {
    /// The system handles the key (and shows its own HUD).
    case passThrough
    /// The key is consumed; a key-down carries what to do, a key-up nothing.
    case swallow(MediaKeyAction?)

    public var swallows: Bool { self != .passThrough }
}

/// Decides, inside the event tap callback, whether PlatyNotch takes a media key. It
/// does only when everything is in place: the tap is healthy and permitted (`active`),
/// the control exists and reads back on this Mac (`available`; brightness only for the
/// display it controls, `brightnessDisplay`), our full HUD would show on the display the
/// user is looking at (`readyDisplays`; the 2 pt indicator does not count), and the main
/// thread is keeping up with earlier keys (no hand-off older than `handOffDeadline`).
/// Otherwise the key passes through and the system HUD shows.
///
/// A key is decided at its first key-down: its repeats and its key-up follow that
/// decision (a key the system started stays the system's), except that a repeat passes
/// as soon as the conditions fail. Mute repeats do nothing. Inactive passes everything.
/// Pure: the app keeps it current from the main actor and the tap reads it under a lock.
public struct MediaKeyGate: Equatable, Sendable {
    /// A hand-off to the main thread still waiting after this long means the app is
    /// hung or badly behind: keys go to the system until it catches up.
    public static let handOffDeadline: TimeInterval = 0.25

    public var active: Bool
    public var available: Set<MediaKeyKind>
    /// Displays (`CGDirectDisplayID`) whose panel would show a full HUD right now.
    public var readyDisplays: Set<UInt32>
    /// A panel not yet placed on a display would show it (tests; no display to match).
    public var readyOnAnyDisplay: Bool
    /// The display whose brightness PlatyNotch sets (the built-in one); brightness keys
    /// pressed with the cursor on another display go to the system.
    public var brightnessDisplay: UInt32?
    private var swallowing: Set<MediaKeyKind> = []
    /// Send times (seconds, monotonic) of hand-offs not yet run on main, oldest first.
    private var pending: [TimeInterval] = []

    public init(active: Bool = false, available: Set<MediaKeyKind> = [], readyDisplays: Set<UInt32> = [],
                readyOnAnyDisplay: Bool = false, brightnessDisplay: UInt32? = nil) {
        self.active = active
        self.available = available
        self.readyDisplays = readyDisplays
        self.readyOnAnyDisplay = readyOnAnyDisplay
        self.brightnessDisplay = brightnessDisplay
    }

    /// Hand-offs sent and not yet run.
    public var pendingHandOffs: Int { pending.count }

    /// The oldest hand-off has waited longer than `handOffDeadline`.
    public func mainIsLate(now: TimeInterval) -> Bool {
        guard let oldest = pending.first else { return false }
        return now - oldest > Self.handOffDeadline
    }

    /// The main thread ran the oldest hand-off.
    public mutating func handOffRan() {
        if !pending.isEmpty { pending.removeFirst() }
    }

    /// `display` is the display under the cursor when the key was pressed (else the main
    /// one); `now` is monotonic seconds. A `.swallow` with an action is a hand-off: the
    /// caller must run it on main and then call `handOffRan()`.
    public mutating func decide(_ event: MediaKeyEvent?, modifiers: MediaKeyModifiers, display: UInt32,
                                now: TimeInterval) -> MediaKeyDecision {
        guard let event, event.kind != .other else { return .passThrough }
        guard active else {
            swallowing.removeAll()
            return .passThrough
        }
        let kind = event.kind
        guard event.isDown else {
            return swallowing.remove(kind) != nil ? .swallow(nil) : .passThrough
        }
        if event.isRepeat {
            guard swallowing.contains(kind) else { return .passThrough }   // the system's key
            if kind == .mute { return .swallow(nil) }                      // holding mute toggles once
        }
        guard ours(kind, modifiers: modifiers, display: display, now: now) else {
            swallowing.remove(kind)
            return .passThrough
        }
        swallowing.insert(kind)
        pending.append(now)
        return .swallow(MediaKeyAction(kind: kind, fine: modifiers.fine))
    }

    private func ours(_ kind: MediaKeyKind, modifiers: MediaKeyModifiers, display: UInt32, now: TimeInterval) -> Bool {
        guard available.contains(kind), !modifiers.opensSystemSettings,
              readyOnAnyDisplay || readyDisplays.contains(display), !mainIsLate(now: now) else { return false }
        if kind.hud == .brightness { return brightnessDisplay == display }
        return true
    }
}

/// Volume and mute after a volume key, as macOS does it: up unmutes, down never does,
/// mute toggles; a muted output shows an empty bar.
public enum VolumeChange {
    public struct State: Equatable, Sendable {
        public var volume: Float
        public var muted: Bool

        public init(volume: Float, muted: Bool) {
            self.volume = volume
            self.muted = muted
        }

        /// The HUD's level.
        public var shownLevel: Float { muted ? 0 : volume }
    }

    public static func apply(_ kind: MediaKeyKind, fine: Bool, to s: State) -> State {
        switch kind {
        case .volumeUp: State(volume: LevelStep.next(s.volume, up: true, fine: fine), muted: false)
        case .volumeDown: State(volume: LevelStep.next(s.volume, up: false, fine: fine), muted: s.muted)
        case .mute: State(volume: s.volume, muted: !s.muted)
        default: s
        }
    }
}
