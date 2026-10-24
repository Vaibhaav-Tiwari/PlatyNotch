import PlatyNotchKit
import SwiftUI

/// The music tile: artwork with a glow in its dominant colour, title and artist, the
/// playing app's icon, a scrubber, previous / play-pause / next, the output device, a
/// favourite button (Apple Music) and the bars (live with the visualiser on).
struct MusicTile: View {
    let nowPlaying: NowPlaying
    let visualiser: MusicVisualiser

    var body: some View {
        if let title = nowPlaying.title {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    artwork
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let artist = nowPlaying.artist {
                            Text(verbatim: artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        source
                    }
                    Spacer(minLength: 4)
                    if nowPlaying.isPlaying {
                        MusicBars(color: nowPlaying.artworkTint ?? Theme.color(.active), count: 6, height: 18,
                                  barWidth: 3, spacing: 2)
                            .environment(\.musicVisualiser, visualiser)
                    }
                }
                if nowPlaying.clock != nil {
                    MusicScrubber(nowPlaying: nowPlaying)
                }
                controls
                if let message = nowPlaying.likeMessage {
                    LikeMessage(text: message, help: nowPlaying.likeHelp)
                }
            }
            .padding(8)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            Label("Nothing playing", systemImage: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var artwork: some View {
        let tint = nowPlaying.artworkTint
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: (tint ?? .clear).opacity(0.75), radius: 10)
        .animation(.easeOut(duration: 0.4), value: tint)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var source: some View {
        if nowPlaying.appName != nil || nowPlaying.outputDevice != nil {
            HStack(spacing: 4) {
                if let icon = nowPlaying.appIcon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12).accessibilityHidden(true)
                }
                Text(verbatim: [nowPlaying.appName, nowPlaying.outputDevice].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if nowPlaying.canLike {
                control(nowPlaying.liked == true ? "heart.fill" : "heart",
                        nowPlaying.liked == true ? "Remove from favourites" : "Add to favourites") { nowPlaying.toggleLike() }
                    .disabled(nowPlaying.likeBusy)
                    .opacity(nowPlaying.likeBusy ? 0.5 : 1)
            }
            Spacer(minLength: 0)
            control("backward.fill", "Previous track") { nowPlaying.previous() }
            control(nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    nowPlaying.isPlaying ? "Pause" : "Play", size: 15) { nowPlaying.playPause() }
            control("forward.fill", "Next track") { nowPlaying.next() }
            Spacer(minLength: 0)
            if nowPlaying.canLike { Color.clear.frame(width: 18, height: 18) }   // keeps the controls centred
        }
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat = 12, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Why the heart did not work, with the Automation buttons when Music refused PlatyNotch.
private struct LikeMessage: View {
    let text: String
    let help: PermissionHelp?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tint(.warning))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let help { PermissionHelpButtons(help: help) }
        }
    }
}

/// Elapsed / remaining and a draggable bar. Ticks once a second only while playing and the
/// panel is shown; a drag seeks on release.
struct MusicScrubber: View {
    let nowPlaying: NowPlaying
    @Environment(\.panelTicking) private var ticking
    @State private var dragging: Double?

    var body: some View {
        // One timeline, paused rather than swapped out, so a drag in progress keeps its view.
        TimelineView(.animation(minimumInterval: 1, paused: !(ticking && nowPlaying.isPlaying && dragging == nil))) { ctx in
            content(now: ctx.date)
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let clock = nowPlaying.clock {
            let position = dragging.map { $0 * clock.duration } ?? clock.position(now: now)
            let progress = dragging ?? clock.progress(now: now)
            HStack(spacing: 6) {
                time(position)
                bar(progress: progress, seekable: clock.duration > 0) { fraction in
                    nowPlaying.seek(to: fraction * clock.duration)
                }
                time(clock.duration > 0 ? -(clock.duration - position) : nil)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Playback position")
            .accessibilityValue(clock.duration > 0
                                ? "\(TodayFormat.clock(position)) of \(TodayFormat.clock(clock.duration))"
                                : TodayFormat.clock(position))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = direction == .increment ? 10 : -10
                nowPlaying.seek(to: clock.position(now: Date()) + step)
            }
        }
    }

    private func time(_ seconds: TimeInterval?) -> some View {
        Text(verbatim: seconds.map { $0 < 0 ? "-" + TodayFormat.clock(-$0) : TodayFormat.clock($0) } ?? "")
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .center)
    }

    private func bar(progress: Double, seekable: Bool, seek: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.3)).frame(height: 3)
                Capsule().fill(.primary.opacity(0.85)).frame(width: w * min(max(progress, 0), 1), height: 3)
                if dragging != nil {
                    Circle().fill(.primary).frame(width: 9, height: 9).offset(x: w * min(max(progress, 0), 1) - 4.5)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in if seekable { dragging = min(max(g.location.x / w, 0), 1) } }
                .onEnded { g in
                    guard seekable else { return }
                    seek(min(max(g.location.x / w, 0), 1))
                    dragging = nil
                })
        }
        .frame(height: 12)
    }
}
