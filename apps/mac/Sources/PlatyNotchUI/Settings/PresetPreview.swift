import PlatyNotchKit
import SwiftUI

/// Settings › General: what a preset looks like before Apply (Island spec 6). The resting
/// pill and the open panel's Home with the preset's dock, folded dock and Agents tab, drawn
/// from fixed sample content at 0.6 scale. It never writes anything: Apply is the only writer.
struct PresetPreview: View {
    let preset: SetupPreset

    static let scale: CGFloat = 0.6
    static let hiddenLine = "Hidden until something is live"

    /// The dock's labels as the preset shows them (every tool available, the default search key).
    static func dockLabels(_ p: SetupPreset) -> [String] {
        let all: Set<String> = Set(DockTool.allCases.flatMap(\.widgetIDs))
        let items = DockState.items(layout: p.layout.dock, toolTitles: [:], enabledWidgets: all, focus: nil,
                                    timers: [], stopwatch: nil, remindersDue: 0, shelfCount: 0,
                                    searchKey: CommandHotKey.presets.first?.display, now: Date())
        return DockView.labels(items, folded: p.layout.prefs.dockFolded)
    }

    /// Everything the preview says, in order: the panel's tabs, the dock, the pill (tests).
    static func texts(_ p: SetupPreset) -> [String] {
        var out: [String] = ["Home"]
        if p.layout.prefs.agentsTab == .always { out.append("Agents") }
        out += dockLabels(p)
        out.append(PresetPillPreview.caption(p))
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PresetPillPreview(preset: preset)
            Self.panel(preset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(preset.title): " + Self.texts(preset).joined(separator: ", "))
    }

    /// The open panel for `p`, built once per preset from the shared sample (nothing starts).
    @MainActor private static var panels: [SetupPreset: AnyView] = [:]
    @MainActor private static var rig: HomeRenders.Rig?

    /// Lets the sample rig and the built previews go (Settings › General closed).
    @MainActor static func releaseCache() {
        panels = [:]
        rig = nil
    }

    @MainActor static var isCached: Bool { rig != nil || !panels.isEmpty }

    @MainActor static func panel(_ p: SetupPreset) -> AnyView {
        if let cached = panels[p] { return cached }
        let sample: HomeRenders.Rig = rig ?? HomeRenders.previewRig()
        rig = sample
        let layout = p.layout
        let width: CGFloat = PanelLayout.expandedSize.width - 2 * Space.panelSide
        // Home's own height at rest (Now Playing, Today and the dock), not the panel's maximum.
        let height: CGFloat = min(HomeRenders.available, 300)
        let inner = HomeRenders.panel(sample, now: HomeRenders.at(hour: 14), full: true, dock: layout.dock,
                                      prefs: layout.prefs, agentsVisible: layout.prefs.agentsTab == .always)
        let view = inner
            .padding(EdgeInsets(top: 8, leading: Space.panelSide, bottom: Space.panelBottom, trailing: Space.panelSide))
            .frame(width: width + 2 * Space.panelSide, height: height + 8 + Space.panelBottom, alignment: .top)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panelBottom, style: .continuous))
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: (width + 2 * Space.panelSide) * scale, height: (height + 8 + Space.panelBottom) * scale,
                   alignment: .topLeading)
            .allowsHitTesting(false)
        let built = AnyView(view)
        panels[p] = built
        return built
    }
}

/// The resting pill for a preset: what it shows first, or hidden (Minimal).
struct PresetPillPreview: View {
    let preset: SetupPreset

    static func caption(_ p: SetupPreset) -> String {
        if p.mode == .minimal { return PresetPreview.hiddenLine }
        return p.layout.prefs.pillOrder == .agentsFirst ? "The pill shows agents first" : "The pill shows music first"
    }

    /// What the pill leads with for the preset when music plays and agents work.
    static func lead(_ p: SetupPreset) -> PillLead? {
        if p.mode == .minimal { return nil }
        return p.layout.prefs.pillOrder == .agentsFirst ? .agents : .music
    }

    var body: some View {
        HStack(spacing: 8) {
            if let lead = Self.lead(preset) {
                let layout = PillRenders.notchLayout(.standard)
                let size = layout.contentRect(for: .compact).size
                PillRenders.lead(lead, greyNotch: false)
                    .scaleEffect(PresetPreview.scale, anchor: .topLeading)
                    .frame(width: size.width * PresetPreview.scale, height: size.height * PresetPreview.scale,
                           alignment: .topLeading)
            } else {
                Capsule()
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: 120, height: 20)
            }
            Text(verbatim: Self.caption(preset))
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
        }
    }
}
