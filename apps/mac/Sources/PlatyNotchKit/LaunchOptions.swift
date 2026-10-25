/// Command-line and environment switches read at launch.
public struct LaunchOptions: Equatable, Sendable {
    /// `--smoke`: start everything, report after `smokeDelay` seconds, exit.
    public var smoke: Bool
    /// `--smoke-settings`: build the Settings and Onboarding windows, visit every
    /// section and page, report and exit (no config is written, nothing is prompted).
    public var smokeSettings: Bool
    /// `--smoke-power`: build an inert instance of every power feature (`WidgetCategory.power`),
    /// lay out its views off screen, print `SMOKE-POWER OK widgets=<n>` and exit. No core,
    /// no window, no permission, nothing read or written.
    public var smokePower: Bool
    /// `PLATYNOTCH_SMOKE_DELAY` seconds (default 3).
    public var smokeDelay: Double
    /// `PLATYNOTCH_EXTERNAL_CORE=1`: connect to an already running `notch serve`
    /// (e.g. `scripts/fake-events.sh`) instead of supervising one.
    public var externalCore: Bool
    /// `PLATYNOTCH_RENDER_DIR`: `--smoke` also writes PNGs of themed views (HUD, approval
    /// card, game boards, shelf) in the dark and light schemes into this directory.
    public var renderDir: String?
    /// `--render-icon <dir>` (hidden, C35): write `<dir>/AppIcon.iconset` (10 PNGs) and exit;
    /// then `iconutil -c icns`. No core, no window.
    public var renderIconDir: String?
    /// `--platy-gallery <dir>` (hidden, C35): write Platy's art review PNGs and exit.
    public var platyGalleryDir: String?
    /// `--pill-gallery <dir>` (hidden): write the compact pill in every state at every
    /// pill width (and the open/close morph frames) and exit.
    public var pillGalleryDir: String?
    /// `PLATYNOTCH_FAKE_NOWPLAYING=1` together with `--perf-run` (scripts/perf-idle.sh
    /// `--state music` passes both): now playing reports a fake track as playing instead of
    /// reading any player, so the pill shows the music bars. Either one alone does nothing.
    public var fakeNowPlaying: Bool
    /// `--perf-run` (scripts/perf-idle.sh): the widget registry does not persist, so a
    /// measurement never writes `widgets.layout` (C4).
    public var perfRun: Bool

    public init(arguments: [String], env: [String: String]) {
        smoke = arguments.dropFirst().contains("--smoke")
        smokeSettings = arguments.dropFirst().contains("--smoke-settings")
        smokePower = arguments.dropFirst().contains("--smoke-power")
        smokeDelay = env["PLATYNOTCH_SMOKE_DELAY"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 3
        externalCore = env["PLATYNOTCH_EXTERNAL_CORE"] == "1"
        renderDir = env["PLATYNOTCH_RENDER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        renderIconDir = Self.value(after: "--render-icon", in: arguments)
        platyGalleryDir = Self.value(after: "--platy-gallery", in: arguments)
        pillGalleryDir = Self.value(after: "--pill-gallery", in: arguments)
        perfRun = arguments.dropFirst().contains("--perf-run")
        fakeNowPlaying = env["PLATYNOTCH_FAKE_NOWPLAYING"] == "1" && perfRun
    }

    /// The argument after `flag`, if there is one that is not another flag.
    static func value(after flag: String, in arguments: [String]) -> String? {
        let args = Array(arguments.dropFirst())
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        let v = args[i + 1]
        return v.isEmpty || v.hasPrefix("--") ? nil : v
    }
}
