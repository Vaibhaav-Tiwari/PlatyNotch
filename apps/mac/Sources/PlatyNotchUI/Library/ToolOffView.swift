import PlatyNotchKit
import SwiftUI

/// A dock tool whose widget is off (Island spec 3.3): one "Turn on <Tool>" button, so the
/// slot never leads nowhere and the user's switches are kept until they choose.
struct ToolOffView: View {
    let title: String
    let onTurnOn: () -> Void

    static func title(for tool: String) -> String { "Turn on \(tool)" }

    var body: some View {
        VStack(spacing: Space.m) {
            PlatyView(mood: .idle, size: 36)
            Text(verbatim: "\(title) is off")
                .font(DS.font(TypeScale.title))
                .foregroundStyle(DS.primary)
            Button(Self.title(for: title), action: onTurnOn)
                .buttonStyle(ToolPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
