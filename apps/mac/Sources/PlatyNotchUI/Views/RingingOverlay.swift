import PlatyNotchKit
import AppKit
import SwiftUI

/// The ringing card below the notch (`PanelLayout.ringingHeight`): a pulsing ring around a
/// bell, what rings, Snooze (alarms, 9 min) and Stop. Buttons work on the first click;
/// nothing here is focusable or has a key equivalent (the panel never takes the keyboard
/// for a ringing card). The pulse is a Core Animation layer (`RingPulseNSView`, no
/// per-frame SwiftUI work), running only while the panel is really shown
/// (`panelTicking`) and Reduce Motion is off; otherwise the ring is still (A2).
struct RingingOverlay: View {
    let title: String
    let subtitle: String
    let isAlarm: Bool
    var onSnooze: (() -> Void)?
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelTicking) private var ticking

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RingPulse(color: NSColor(Theme.color(.attention)), pulses: ticking && !reduceMotion)
                Circle().fill(Theme.color(.attention).opacity(0.2))
                Image(systemName: isAlarm ? "alarm.fill" : "timer")
                    .font(.system(size: IconSize.header, weight: .semibold))
                    .foregroundStyle(Theme.color(.attention))
            }
            .frame(width: 46, height: 46)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if let onSnooze {
                Button("Snooze", action: onSnooze)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .focusable(false)
                    .help("Ring again in 9 minutes")
            }
            Button("Stop", action: onStop)
                .buttonStyle(.borderedProminent)
                .tint(Theme.color(.attention))
                .controlSize(.regular)
                .focusable(false)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) ringing")
    }
}

private struct RingPulse: NSViewRepresentable {
    let color: NSColor
    let pulses: Bool

    func makeNSView(context: Context) -> RingPulseNSView { RingPulseNSView() }

    func updateNSView(_ view: RingPulseNSView, context: Context) {
        view.configure(color: color, pulses: pulses)
    }
}

/// A stroked circle that grows (0.9 → 1.35) and fades out every 1.1 s on the render
/// server; still (scale 0.9, 80% opacity) when not pulsing.
final class RingPulseNSView: NSView {
    static let pulseKey = "ring.pulse"
    private let ring = CAShapeLayer()
    private var color: NSColor = .systemOrange
    private var pulses = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 3
        ring.opacity = 0.8
        ring.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "strokeColor": NSNull(),
                        "transform": NSNull(), "opacity": NSNull()]
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ring.transform = CATransform3DMakeScale(0.9, 0.9, 1)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    func configure(color: NSColor, pulses: Bool) {
        if color != self.color {
            self.color = color
            applyColor()
        }
        guard pulses != self.pulses || (pulses && !isPulsing) else { return }
        self.pulses = pulses
        ring.removeAnimation(forKey: Self.pulseKey)
        guard pulses else { return }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.9
        grow.toValue = 1.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.8
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 1.1
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        ring.add(group, forKey: Self.pulseKey)
    }

    var isPulsing: Bool { ring.animation(forKey: Self.pulseKey) != nil }

    private func applyColor() {
        var cg: CGColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = self.color.cgColor }
        ring.strokeColor = cg
    }
}
