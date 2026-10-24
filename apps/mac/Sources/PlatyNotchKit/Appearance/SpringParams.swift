import Foundation

/// The panel's open / close animation: a spring (`response` seconds, `dampingFraction`)
/// and a blur that the new content settles out of (points; 0 turns it off).
public struct SpringParams: Codable, Equatable, Sendable {
    public var response: Double
    public var dampingFraction: Double
    public var blur: Double

    public static let standard = SpringParams(response: 0.42, dampingFraction: 0.78, blur: 8)
    public static let responseRange: ClosedRange<Double> = 0.2...1.0
    public static let dampingRange: ClosedRange<Double> = 0.5...1.0
    public static let blurRange: ClosedRange<Double> = 0...20

    public init(response: Double, dampingFraction: Double, blur: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
        self.blur = blur
    }

    /// Missing keys keep the standard values (older or hand-edited settings).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.standard
        response = (try? c.decodeIfPresent(Double.self, forKey: .response)) ?? d.response
        dampingFraction = (try? c.decodeIfPresent(Double.self, forKey: .dampingFraction)) ?? d.dampingFraction
        blur = (try? c.decodeIfPresent(Double.self, forKey: .blur)) ?? d.blur
    }

    /// Each value inside its range; a non-finite one becomes the standard value.
    public func clamped() -> SpringParams {
        let d = Self.standard
        return SpringParams(response: Self.clamp(response, Self.responseRange, d.response),
                            dampingFraction: Self.clamp(dampingFraction, Self.dampingRange, d.dampingFraction),
                            blur: Self.clamp(blur, Self.blurRange, d.blur))
    }

    static func clamp(_ v: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
        guard v.isFinite else { return fallback }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}
