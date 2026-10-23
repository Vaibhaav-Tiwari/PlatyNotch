import PlatyNotchKit
import SwiftUI

/// What the panel's SwiftUI content reads; written by `NotchController`.
@MainActor @Observable
final class PanelViewModel {
    var mode: PanelMode = .compact
    var visible = false
    var layout: PanelLayout?
    var onClick: () -> Void = {}
}

/// Places the mode's content inside the fixed-size panel window.
struct PanelRootView: View {
    let model: PanelViewModel
    let store: AppStore

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let layout = model.layout {
                let r = PanelLayout.localRect(layout.contentRect(for: model.mode), in: layout.windowFrame)
                PanelPlaceholderView(mode: model.mode, connection: store.connection, hasNotch: layout.hasNotch)
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .onTapGesture { model.onClick() }
                    .offset(x: r.minX, y: r.minY)
                    .opacity(model.visible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(duration: 0.25), value: model.mode)
        .animation(.easeOut(duration: 0.15), value: model.visible)
    }
}

/// Temporary content until Plan 3 Task 6: shows the panel mode and core connection.
struct PanelPlaceholderView: View {
    let mode: PanelMode
    let connection: ConnectionState
    let hasNotch: Bool

    var body: some View {
        ZStack {
            shape.fill(.black)
            switch mode {
            case .hidden, .compact:
                HStack {
                    Circle().fill(dotColor).frame(width: 8, height: 8)
                    Spacer(minLength: 0)
                    if !hasNotch { label }
                    Spacer(minLength: 0)
                    Text(mode == .hidden ? "" : "•").foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 14)
            case .peek, .expanded:
                VStack(spacing: 6) {
                    Text("PlatyNotch").font(.headline)
                    label
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var label: some View {
        Text("\(mode.description) · \(connectionText)")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
    }

    /// Square top corners against the notch; a fully rounded pill otherwise.
    private var shape: some Shape {
        let top: CGFloat = hasNotch ? 0 : 14
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: 14,
                                      bottomTrailingRadius: 14, topTrailingRadius: top, style: .continuous)
    }

    private var connectionText: String {
        switch connection {
        case .connecting: "connecting"
        case .connected: "connected"
        case .reconnecting: "reconnecting"
        }
    }

    private var dotColor: Color {
        switch connection {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        }
    }
}
