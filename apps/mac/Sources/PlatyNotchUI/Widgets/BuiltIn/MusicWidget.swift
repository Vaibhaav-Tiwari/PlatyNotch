import PlatyNotchKit
import SwiftUI

/// Now playing: a tile with track and controls, and music bars in the pill while playing.
/// Reading starts when the widget starts (at launch when enabled), so the pill shows
/// music without the Today tab ever being opened.
@MainActor
final class MusicWidget: NotchWidget {
    static let widgetID = "music"

    let id = MusicWidget.widgetID
    let title = "Music"
    let systemImage = "music.note"
    let defaultEnabled = true
    let nowPlaying: NowPlaying

    init(nowPlaying: NowPlaying) {
        self.nowPlaying = nowPlaying
    }

    var liveActivities: [LiveActivity] {
        guard nowPlaying.isPlaying else { return [] }
        return [LiveActivity(id: "music:playing", widgetID: id, priority: LivePriority.musicPlaying, glyph: .musicBars,
                             tint: .accent, accessibilityLabel: "Music playing")]
    }

    func start(context: WidgetContext) { nowPlaying.start() }
    func stop() { nowPlaying.stop() }

    func tileView() -> AnyView {
        let nowPlaying = self.nowPlaying
        return AnyView(NowPlayingCard(nowPlaying: nowPlaying)
            .onAppear { nowPlaying.setVisible(true) }
            .onDisappear { nowPlaying.setVisible(false) })
    }
}

struct NowPlayingCard: View {
    let nowPlaying: NowPlaying

    var body: some View {
        if let title = nowPlaying.title {
            HStack(spacing: 8) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if let artist = nowPlaying.artist {
                        Text(verbatim: artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                HStack(spacing: 10) {
                    control("backward.fill", "Previous track") { nowPlaying.previous() }
                    control(nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                            nowPlaying.isPlaying ? "Pause" : "Play") { nowPlaying.playPause() }
                    control("forward.fill", "Next track") { nowPlaying.next() }
                }
            }
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Label("Nothing playing", systemImage: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var artwork: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 32, height: 32)
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
