import PlatyNotchKit
import SwiftUI

/// Agents' header usage (Island spec 8, wireframe E): per agent a 14 pt ring, its arc on a
/// white 0.15 track, green, amber from 80 %, red from 95 %, then "Claude 62%" (12 pt secondary).
struct UsageRingsView: View {
    let rings: [UsageRing]

    static let diameter: CGFloat = 14
    static let lineWidth: CGFloat = 2.5

    /// The words beside the rings (tests).
    static func texts(_ rings: [UsageRing]) -> [String] { rings.map(\.text) }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(rings.enumerated()), id: \.offset) { _, ring in
                HStack(spacing: 5) {
                    ZStack {
                        Circle().stroke(DS.ink(0.15), lineWidth: Self.lineWidth)
                        Circle().trim(from: 0, to: ring.fraction)
                            .stroke(DS.color(ring.tone), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: Self.diameter, height: Self.diameter)
                    Text(verbatim: ring.text)
                        .font(DS.font(TypeScale.secondary))
                        .foregroundStyle(DS.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(ring.name) usage \(Int((ring.fraction * 100).rounded())) percent of five hours")
            }
        }
    }
}
