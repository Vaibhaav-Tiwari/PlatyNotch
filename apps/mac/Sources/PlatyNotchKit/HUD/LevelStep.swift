import Foundation

/// Steps a 0…1 level (volume, brightness, keyboard backlight) the way the system HUD
/// does: 16 steps, or 64 with ⌥⇧ (quarter steps). A level off the grid moves to the
/// next grid point in that direction; the result is clamped to 0…1.
public enum LevelStep {
    public static let coarseSteps = 16
    public static let fineSteps = 64

    public static func next(_ current: Float, up: Bool, fine: Bool) -> Float {
        let n = Float(fine ? fineSteps : coarseSteps)
        let level = current.isNaN ? 0 : min(max(current, 0), 1)
        let position = level * n
        // Levels read back from hardware sit a hair off the grid; treat those as on it.
        let slack: Float = 0.001
        let target = up ? (position + slack).rounded(.down) + 1 : (position - slack).rounded(.up) - 1
        return min(max(target / n, 0), 1)
    }
}
