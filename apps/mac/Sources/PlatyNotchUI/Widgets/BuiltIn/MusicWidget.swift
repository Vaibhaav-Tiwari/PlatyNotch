import PlatyNotchKit
import SwiftUI

/// Now playing: a tile (`MusicTile`: artwork glow, scrubber, controls) and music bars in
/// the pill while playing. Reading starts when the widget starts (at launch when enabled),
/// so the pill shows music without the Today tab ever being opened.
///
/// The live visualiser (`MusicVisualiser`) is a separate toggle in this widget's settings,
/// off by default; its audio tap and permission prompt only ever start from that toggle.
@MainActor
final class MusicWidget: NotchWidget {
    static let widgetID = "music"

    let id = MusicWidget.widgetID
    let title = "Music"
    let systemImage = "music.note"
    let defaultEnabled = true
    let nowPlaying: NowPlaying
    let visualiser: MusicVisualiser

    init(nowPlaying: NowPlaying, visualiser: MusicVisualiser) {
        self.nowPlaying = nowPlaying
        self.visualiser = visualiser
    }

    var liveActivities: [LiveActivity] {
        guard nowPlaying.isPlaying else { return [] }
        return [LiveActivity(id: "music:playing", widgetID: id, priority: LivePriority.musicPlaying, glyph: .musicBars,
                             tint: .accent, accessibilityLabel: "Music playing")]
    }

    func start(context: WidgetContext) {
        let visualiser = self.visualiser
        nowPlaying.onPlayingChange = { visualiser.setPlaying($0) }
        nowPlaying.start()
        visualiser.setPlaying(nowPlaying.isPlaying)
        visualiser.setWidgetRunning(true)
    }

    func stop() {
        visualiser.setWidgetRunning(false)   // the tap stops with the widget
        nowPlaying.onPlayingChange = nil
        nowPlaying.stop()
        visualiser.setPlaying(false)
    }

    func tileView() -> AnyView {
        let nowPlaying = self.nowPlaying
        return AnyView(MusicTile(nowPlaying: nowPlaying, visualiser: visualiser)
            .onAppear { nowPlaying.setVisible(true) }
            .onDisappear { nowPlaying.setVisible(false) })
    }

    func settingsView() -> AnyView? {
        AnyView(MusicSettingsView(visualiser: visualiser))
    }
}

/// Settings › Widgets › Music.
struct MusicSettingsView: View {
    let visualiser: MusicVisualiser

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Live visualiser", isOn: Binding(get: { visualiser.enabled }, set: { visualiser.setEnabled($0) }))
            if visualiser.needsReenable {
                HStack {
                    Text("Turned off: PlatyNotch was updated or reinstalled, so macOS may need to ask once more.")
                        .foregroundStyle(Theme.color(.attention))
                    Button("Turn On Again") { visualiser.setEnabled(true) }
                }
                .font(.system(size: 11))
            }
            Text("""
            The music bars follow what your Mac is playing. macOS asks for System Audio \
            Recording when you turn this on. PlatyNotch listens only while music plays and the \
            bars are on screen; the sound is reduced to bar heights in memory and never \
            recorded, saved or sent.
            """)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
