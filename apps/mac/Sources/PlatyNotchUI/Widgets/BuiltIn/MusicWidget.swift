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

    /// Music stays live this long after a pause (spec 6.2).
    static let pausedWindow: TimeInterval = 600

    var kind: WidgetKind { [.live, .tool] }

    var liveActivities: [LiveActivity] {
        let track: String? = nowPlaying.title.map { title in
            nowPlaying.artist.map { "\(title) — \($0)" } ?? title
        }
        if nowPlaying.isPlaying {
            return [LiveActivity(id: "music:playing", widgetID: id, priority: LivePriority.musicPlaying, glyph: .musicBars,
                                 tint: .accent, accessibilityLabel: "Music playing", title: "Music", subtitle: track)]
        }
        guard let pausedAt = nowPlaying.pausedAt, nowPlaying.info != nil else { return [] }
        return [LiveActivity(id: "music:paused", widgetID: id, priority: LivePriority.musicPlaying,
                             glyph: .symbol("pause.fill"), tint: .neutral,
                             expiresAt: pausedAt.addingTimeInterval(Self.pausedWindow),
                             accessibilityLabel: "Music paused", title: "Music", subtitle: track, startedAt: pausedAt)]
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

    /// Artwork, track and artist, and Play / Pause (the keyline takes the artwork's tint).
    func heroView() -> AnyView? { AnyView(MusicHero(nowPlaying: nowPlaying)) }

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

/// The music hero: artwork (or a note), the track, the artist and one Play / Pause.
struct MusicHero: View {
    let nowPlaying: NowPlaying

    var body: some View {
        let playing: Bool = nowPlaying.isPlaying
        let title: String = HeroPrimary.title(rank: .music, playing: playing, hasLink: false) ?? "Play"
        let np = nowPlaying
        HeroLayout(title: nowPlaying.title ?? "Music", subtitle: subtitle,
                   action: HeroAction(title: title, systemImage: playing ? "pause.fill" : "play.fill",
                                      run: { np.playPause() })) {
            artwork
        } value: {
            Label(playing ? "Playing" : "Paused", systemImage: playing ? "waveform" : "pause.circle")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String? {
        [nowPlaying.artist, nowPlaying.appName].compactMap { $0 }.first
    }

    private var artwork: some View {
        let side: CGFloat = 96
        return Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    DS.icon("music.note", size: IconSize.hero).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityHidden(true)
    }
}
