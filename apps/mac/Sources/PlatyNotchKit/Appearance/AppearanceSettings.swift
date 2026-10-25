import Foundation

/// Settings › Appearance: how the notch panel looks and opens. The one source of truth
/// for these (saved by `AppearanceStore`); the panels read nothing else.
public struct AppearanceSettings: Codable, Equatable, Sendable {
    /// Always on: the pill always shows. Minimal: hidden while nothing is live.
    public enum Mode: String, Codable, CaseIterable, Sendable { case alwaysOn, minimal }
    /// What opens the panel from the pill.
    public enum OpenTrigger: String, Codable, CaseIterable, Sendable { case hover, click }
    /// The compact pill's ears (beside a notch) or its width (without one).
    public enum PillWidth: String, Codable, CaseIterable, Sendable { case compact, standard, wide }
    public typealias Side = LiveSide
    /// Which displays get a panel.
    public enum DisplayChoice: String, Codable, CaseIterable, Sendable {
        /// The display with the menu bar.
        case main
        case all
        /// Displays with a camera notch (the menu-bar display when none has one).
        case withNotch
    }
    /// The panel's color scheme.
    public enum Theme: String, Codable, CaseIterable, Sendable { case system, dark, light }
    /// The open panel's material (spec 7.1): opaque near-black, or the system glass on
    /// macOS 26 (opaque elsewhere). The pill and the notch band are black either way.
    public enum SurfaceStyle: String, Codable, CaseIterable, Sendable { case opaque, glass }

    public var mode: Mode = .alwaysOn
    public var openOn: OpenTrigger = .hover
    /// Seconds the cursor rests on the pill before it opens (hover mode). 0.12 is the
    /// debouncer's long-standing default (C32), not the plan's 0.15.
    public var hoverDelay: Double = HoverDebouncer.defaultEnterDelay
    public var pillWidth: PillWidth = .standard
    public var liveSide: Side = .right
    public var displays: DisplayChoice = .main
    /// Dark by default (Task 12 ruling, not the plan's `.system`): on a notched display the
    /// panel joins the black camera housing, which a light panel would show as a hole.
    public var theme: Theme = .dark
    /// The old spring sliders' value. Kept (and saved) so older versions read it, but no
    /// view reads it any more: `motion` replaced it (spec 9).
    public var spring: SpringParams = .standard
    /// Calm, Lively or Reduced (spec 9). Settings without it migrate from `spring`.
    public var motion: MotionPreset = .calm
    public var surface: SurfaceStyle = .opaque
    /// Hide the pill over full-screen apps (top edge reveals it). Never hides a pending
    /// approval, a ringing alarm or timer, the open panel or the drop zone.
    public var hideInFullScreen = true
    /// Platy, the mascot, in the compact pill and the empty states (C36). Off gives the
    /// plain look: agent dots only, no mascot.
    public var showPlaty = true

    public static let hoverDelayRange: ClosedRange<Double> = 0...1

    public init(mode: Mode = .alwaysOn, openOn: OpenTrigger = .hover,
                hoverDelay: Double = HoverDebouncer.defaultEnterDelay, pillWidth: PillWidth = .standard,
                liveSide: Side = .right, displays: DisplayChoice = .main, theme: Theme = .dark,
                spring: SpringParams = .standard, hideInFullScreen: Bool = true, showPlaty: Bool = true,
                motion: MotionPreset = .calm, surface: SurfaceStyle = .opaque) {
        self.mode = mode
        self.openOn = openOn
        self.hoverDelay = hoverDelay
        self.pillWidth = pillWidth
        self.liveSide = liveSide
        self.displays = displays
        self.theme = theme
        self.spring = spring
        self.hideInFullScreen = hideInFullScreen
        self.showPlaty = showPlaty
        self.motion = motion
        self.surface = surface
    }

    private enum CodingKeys: String, CodingKey {
        case mode, openOn, hoverDelay, pillWidth, liveSide, displays, theme, spring, hideInFullScreen, showPlaty, motion, surface
    }

    /// Missing keys and unknown cases keep the defaults, so `{}` (or a value from an older
    /// or newer version) always decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppearanceSettings()
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? d.mode
        openOn = (try? c.decodeIfPresent(OpenTrigger.self, forKey: .openOn)) ?? d.openOn
        hoverDelay = (try? c.decodeIfPresent(Double.self, forKey: .hoverDelay)) ?? d.hoverDelay
        pillWidth = (try? c.decodeIfPresent(PillWidth.self, forKey: .pillWidth)) ?? d.pillWidth
        liveSide = (try? c.decodeIfPresent(Side.self, forKey: .liveSide)) ?? d.liveSide
        displays = (try? c.decodeIfPresent(DisplayChoice.self, forKey: .displays)) ?? d.displays
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        spring = (try? c.decodeIfPresent(SpringParams.self, forKey: .spring)) ?? d.spring
        hideInFullScreen = (try? c.decodeIfPresent(Bool.self, forKey: .hideInFullScreen)) ?? d.hideInFullScreen
        showPlaty = (try? c.decodeIfPresent(Bool.self, forKey: .showPlaty)) ?? d.showPlaty
        motion = (try? c.decodeIfPresent(MotionPreset.self, forKey: .motion))
            ?? Self.migratedMotion(from: spring)
        surface = (try? c.decodeIfPresent(SurfaceStyle.self, forKey: .surface)) ?? d.surface
    }

    /// The spring and hover delay inside their ranges.
    public func clamped() -> AppearanceSettings {
        var s = self
        s.spring = spring.clamped()
        s.hoverDelay = SpringParams.clamp(hoverDelay, Self.hoverDelayRange, HoverDebouncer.defaultEnterDelay)
        return s
    }

    /// Whether going from `old` to these settings needs new panels (which displays, or
    /// the window geometry). Everything else is applied to the existing panels live.
    public func needsRebuild(from old: AppearanceSettings) -> Bool {
        displays != old.displays || pillWidth != old.pillWidth
    }
}

extension AppearanceSettings {
    /// The surface in effect: glass only where the system has it.
    public func effectiveSurface(glassAvailable: Bool) -> SurfaceStyle {
        surface == .glass && glassAvailable ? .glass : .opaque
    }

    /// The surface for `mode`: glass only for the open panel (spec 7.1) and never while it
    /// shows approvals; the approval peek and every other surface stay opaque, so an
    /// approval is always read on a solid background.
    public func effectiveSurface(glassAvailable: Bool, mode: PanelMode, approvalsShowing: Bool) -> SurfaceStyle {
        guard mode == .expanded, !approvalsShowing else { return .opaque }
        return effectiveSurface(glassAvailable: glassAvailable)
    }

    /// Settings saved before Motion: Lively only when the old sliders were set springier
    /// or slower than the new Calm open (damping under 0.86 or response over 0.42).
    /// An untouched spring, or one with only the blur changed, is Calm.
    static func migratedMotion(from spring: SpringParams) -> MotionPreset {
        let d = SpringParams.standard
        if spring.response == d.response, spring.dampingFraction == d.dampingFraction { return .calm }
        guard let calm = MotionPreset.calm.spring(.open) else { return .calm }
        return spring.dampingFraction < calm.damping || spring.response > d.response ? .lively : .calm
    }
}

extension AppearanceSettings.DisplayChoice {
    /// The indices of the screens that get a panel, given each screen's notch (first is
    /// the menu-bar display). Never empty while there is a screen.
    public func select(hasNotch: [Bool]) -> [Int] {
        guard !hasNotch.isEmpty else { return [] }
        switch self {
        case .main: return [0]
        case .all: return Array(hasNotch.indices)
        case .withNotch:
            let notched = hasNotch.indices.filter { hasNotch[$0] }
            return notched.isEmpty ? [0] : notched
        }
    }
}

/// Saves `AppearanceSettings` as JSON in UserDefaults under `key`. The first load
/// without it takes the Plan 3 keys (`legacyKeys`) as its initial values; they are
/// never read again once the settings are saved, and never written.
public enum AppearanceStore {
    public static let key = "appearance.settings"
    /// The Plan 3 keys: "Minimal" (Bool), "Show on all displays" (Bool), live side ("left" / "right").
    public enum LegacyKey {
        public static let minimal = "appearance.minimal"
        public static let showOnAllDisplays = "appearance.showOnAllDisplays"
        public static let liveSide = "appearance.liveSide"
    }

    public static func load(from defaults: UserDefaults) -> AppearanceSettings {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(AppearanceSettings.self, from: data) {
            return saved.clamped()
        }
        return migrated(from: defaults)
    }

    public static func save(_ settings: AppearanceSettings, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    /// The defaults with the Plan 3 keys applied.
    static func migrated(from defaults: UserDefaults) -> AppearanceSettings {
        var s = AppearanceSettings()
        if defaults.bool(forKey: LegacyKey.minimal) { s.mode = .minimal }
        if defaults.bool(forKey: LegacyKey.showOnAllDisplays) { s.displays = .all }
        if let raw = defaults.string(forKey: LegacyKey.liveSide), let side = LiveSide(rawValue: raw) {
            s.liveSide = side
        }
        return s
    }
}
