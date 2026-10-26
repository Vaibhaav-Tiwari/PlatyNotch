import Foundation

/// The colours of Platy's pond in Now's idle hero (spec 8.2), one set per `DayPhase`:
/// morning light, a clear day, evening dusk and a night sky with stars. The greeting sits on
/// the pond, so white and cream text reach 4.5:1 on every one of them.
public struct PondPalette: Equatable, Sendable {
    public let skyTop: RGB
    public let skyBottom: RGB
    public let water: RGB
    /// Stars over the pond (night only).
    public let stars: Bool

    public init(skyTop: RGB, skyBottom: RGB, water: RGB, stars: Bool) {
        self.skyTop = skyTop
        self.skyBottom = skyBottom
        self.water = water
        self.stars = stars
    }

    public static func of(_ phase: DayPhase) -> PondPalette {
        switch phase {
        case .morning:
            PondPalette(skyTop: RGB(hex: 0x3E6A7A), skyBottom: RGB(hex: 0x44686A), water: RGB(hex: 0x1C3B4A), stars: false)
        case .day:
            PondPalette(skyTop: RGB(hex: 0x2E5E73), skyBottom: RGB(hex: 0x3F6670), water: RGB(hex: 0x1C3B4A), stars: false)
        case .evening:
            PondPalette(skyTop: RGB(hex: 0x3A2F4F), skyBottom: RGB(hex: 0x5A4048), water: RGB(hex: 0x18303D), stars: false)
        case .night:
            PondPalette(skyTop: RGB(hex: 0x0D1626), skyBottom: RGB(hex: 0x1C3B4A), water: RGB(hex: 0x0F2230), stars: true)
        }
    }
}
