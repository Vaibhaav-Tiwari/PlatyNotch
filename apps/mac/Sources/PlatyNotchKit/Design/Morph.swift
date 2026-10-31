import Foundation

/// The matched-geometry ids of the open/close morph (spec 9): what in the pill grows into
/// its place in the open panel (Platy into the header).
public enum MorphID {
    /// Platy: the pill's leading glyph and the hero's Platy (agents hero, Today summary).
    public static let platy = "morph.platy"

    /// A live item's glyph: the pill's trailing glyph and the hero's glyph for item `id`.
    public static func live(_ id: String) -> String { "morph.live.\(id)" }
}

/// When the open/close morph applies. Under Reduced motion (and Reduce Motion) nothing
/// morphs: the mode change is a cross-fade only.
public enum Morph {
    /// The pill's trailing glyph morphs into the hero's glyph only when both show the same
    /// live item.
    public static func matches(pillTrailingID: String?, heroTopID: String?, motion: MotionPreset) -> Bool {
        guard motion != .reduced, let pillTrailingID, let heroTopID else { return false }
        return pillTrailingID == heroTopID
    }

    /// Platy moves between the pill and the hero unless motion is reduced.
    public static func morphsPlaty(motion: MotionPreset) -> Bool {
        motion != .reduced
    }
}
