import PlatyNotchKit
import SwiftUI

/// The music tile: artwork with a glow in its dominant colour, title and artist, the
/// playing app's icon, a scrubber, previous / play-pause / next, the output device, a
/// favourite button (Apple Music) and the bars (live with the visualiser on).
struct MusicTile: View {
    let nowPlaying: NowPlaying
    let visualiser: MusicVisualiser
    @Environment(\.inLibraryTool) private var inTool

    /// The Library tool's artwork.
    static let toolArtwork: CGFloat = 116

    var body: some View {
        if inTool {
            tool
        } else {
            tile
        }
    }

    /// Full-panel: large artwork beside the title, artist and source; under the whole
    /// player the scrubber (always: a still bar while the player gives no position) and the
    /// transport, centred; the player centred in the tool's room.
    @ViewBuilder private var tool: some View {
        if let title = nowPlaying.title {
            VStack(spacing: Space.l) {
                HStack(alignment: .center, spacing: Space.xl) {
                    artwork(size: Self.toolArtwork)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(alignment: .center, spacing: Space.s) {
                            Text(verbatim: title)
                                .font(DS.font(TypeScale.title))
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: Space.s)
                            if nowPlaying.isPlaying {
                                MusicBars(color: nowPlaying.artworkTint ?? Theme.color(.active), count: 6, height: 16,
                                          barWidth: 3, spacing: 2)
                                    .environment(\.musicVisualiser, visualiser)
                            }
                        }
                        if let artist = nowPlaying.artist {
                            Text(verbatim: artist)
                                .font(DS.font(TypeScale.body))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        source
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if nowPlaying.clock != nil {
                    MusicScrubber(nowPlaying: nowPlaying)
                } else {
                    MusicScrubberPlaceholder()
                }
                controls(size: 15, playSize: 22, spacing: 28)
                if let message = nowPlaying.likeMessage {
                    LikeMessage(text: message, help: nowPlaying.likeHelp)
                }
            }
            .padding(.horizontal, Space.xs)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ToolEmptyState(systemImage: "music.note", title: "Nothing playing",
                           detail: "Play something in Music, Spotify or your browser and it shows here.")
        }
    }

    @ViewBuilder private var tile: some View {
        if let title = nowPlaying.title {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    artwork(size: 44)
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
                controls(size: 12, playSize: 15, spacing: 14)
                if let message = nowPlaying.likeMessage {
                    LikeMessage(text: message, help: nowPlaying.likeHelp)
                }
            }
            .padding(8)
            .dsCard()
        } else {
            Label("Nothing playing", systemImage: "music.note")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private func artwork(size: CGFloat) -> some View {
        let tint = nowPlaying.artworkTint
        let symbol: CGFloat = size > 60 ? IconSize.hero : 18
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note").font(.system(size: symbol)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.inner(outer: Radius.card, padding: Space.s), style: .continuous))
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
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func controls(size: CGFloat, playSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            if nowPlaying.canLike {
                control(nowPlaying.liked == true ? "heart.fill" : "heart",
                        nowPlaying.liked == true ? "Remove from favourites" : "Add to favourites", size: size) {
                    nowPlaying.toggleLike()
                }
                    .disabled(nowPlaying.likeBusy)
                    .opacity(nowPlaying.likeBusy ? 0.5 : 1)
            }
            Spacer(minLength: 0)
            control("backward.fill", "Previous track", size: size) { nowPlaying.previous() }
            control(nowPlaying.isPlaying ? "pause.fill" : "play.fill",
                    nowPlaying.isPlaying ? "Pause" : "Play", size: playSize) { nowPlaying.playPause() }
            control("forward.fill", "Next track", size: size) { nowPlaying.next() }
            Spacer(minLength: 0)
            if nowPlaying.canLike {   // keeps the controls centred
                Color.clear.frame(width: max(18, size + 6), height: max(18, size + 6))
            }
        }
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat = 12, action: @escaping () -> Void) -> some View {
        let box: CGFloat = max(18, size + 6)
        return Button(action: action) {
            Image(systemName: symbol).font(.system(size: size)).frame(width: box, height: box).contentShape(Rectangle())
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
                .font(DS.font(TypeScale.caption))
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
            .font(DS.font(TypeScale.caption, design: .rounded).weight(.medium))
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

/// The scrubber's place while the player reports no position: a still, empty bar.
struct MusicScrubberPlaceholder: View {
    var body: some View {
        HStack(spacing: 6) {
            label
            Capsule().fill(.secondary.opacity(0.3)).frame(height: 3)
            label
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }

    private var label: some View {
        Text(verbatim: "--:--")
            .font(DS.font(TypeScale.caption, design: .rounded).weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(width: 34, alignment: .center)
    }
}
