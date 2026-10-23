/// Command-line and environment switches read at launch.
public struct LaunchOptions: Equatable, Sendable {
    /// `--smoke`: start everything, report after `smokeDelay` seconds, exit.
    public var smoke: Bool
    /// `--smoke-settings`: build the Settings and Onboarding windows, visit every
    /// section and page, report and exit (no config is written, nothing is prompted).
    public var smokeSettings: Bool
    /// `PLATYNOTCH_SMOKE_DELAY` seconds (default 3).
    public var smokeDelay: Double
    /// `PLATYNOTCH_EXTERNAL_CORE=1`: connect to an already running `notch serve`
    /// (e.g. `scripts/fake-events.sh`) instead of supervising one.
    public var externalCore: Bool

    public init(arguments: [String], env: [String: String]) {
        smoke = arguments.dropFirst().contains("--smoke")
        smokeSettings = arguments.dropFirst().contains("--smoke-settings")
        smokeDelay = env["PLATYNOTCH_SMOKE_DELAY"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 3
        externalCore = env["PLATYNOTCH_EXTERNAL_CORE"] == "1"
    }
}
