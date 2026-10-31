import Foundation

/// What the sky shows, from a WMO code (Island spec 5).
public enum WeatherCondition: String, CaseIterable, Sendable {
    case clear, clouds, rain, thunder, snow, fog

    /// 0, 1 clear; 45, 48 fog; 51–67 and 80–82 rain; 71–77, 85, 86 snow; 95–99 thunder;
    /// everything else (2, 3 and unknown codes) clouds.
    public static func of(code: Int) -> WeatherCondition {
        switch code {
        case 0, 1: .clear
        case 45, 48: .fog
        case 51...67, 80...82: .rain
        case 71...77, 85, 86: .snow
        case 95...99: .thunder
        default: .clouds
        }
    }
}

/// The Core Animation motion a sky runs while the panel is open.
public enum SkyMotion: Sendable, Equatable {
    case none, drift, streaks, flash, flakes
}

/// A condition's gradient (stops top-left to bottom-right at `angle` degrees, CSS-style)
/// and its motion. Text on it is white; every first stop keeps 3:1 with white.
public struct WeatherSky: Equatable, Sendable {
    public let stops: [RGB]
    public let locations: [Double]
    /// CSS `linear-gradient` angle: 180 is straight down, 160 leans to the right.
    public let angle: Double
    public let motion: SkyMotion

    public init(stops: [RGB], locations: [Double], angle: Double, motion: SkyMotion) {
        self.stops = stops
        self.locations = locations
        self.angle = angle
        self.motion = motion
    }

    private static let nightNavy = [RGB(hex: 0x0D1530), RGB(hex: 0x1F2C58)]

    public static func of(_ c: WeatherCondition, isDay: Bool) -> WeatherSky {
        switch c {
        case .clear:
            isDay
                ? WeatherSky(stops: [RGB(hex: 0x3D8BF0), RGB(hex: 0x6FB1F7), RGB(hex: 0xF7C56B)],
                             locations: [0, 0.55, 1], angle: 160, motion: .none)
                : WeatherSky(stops: nightNavy, locations: [0, 1], angle: 170, motion: .none)
        case .clouds:
            WeatherSky(stops: isDay ? [RGB(hex: 0x4A5568), RGB(hex: 0x8A94A6)] : nightNavy,
                       locations: [0, 1], angle: 170, motion: .drift)
        case .rain:
            isDay
                ? WeatherSky(stops: [RGB(hex: 0x3B4B63), RGB(hex: 0x56677F), RGB(hex: 0x6D7D93)],
                             locations: [0, 0.6, 1], angle: 170, motion: .streaks)
                : WeatherSky(stops: nightNavy, locations: [0, 1], angle: 170, motion: .streaks)
        case .thunder:
            WeatherSky(stops: [RGB(hex: 0x1E1B26), RGB(hex: 0x3A2F55)], locations: [0, 1], angle: 170, motion: .flash)
        case .snow:
            WeatherSky(stops: [RGB(hex: 0x4A74A8), RGB(hex: 0x8FB2DA)], locations: [0, 1], angle: 170, motion: .flakes)
        case .fog:
            WeatherSky(stops: [RGB(hex: 0x6B7078), RGB(hex: 0x8E939B)], locations: [0, 1], angle: 170, motion: .none)
        }
    }

    public static func of(_ w: WeatherNow) -> WeatherSky {
        of(WeatherCondition.of(code: w.code), isDay: w.isDay)
    }
}
