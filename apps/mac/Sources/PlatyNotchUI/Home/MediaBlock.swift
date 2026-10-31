import PlatyNotchKit
import SwiftUI

/// Home's left column (spec 2.2): 54 pt art, title, artist, a 3 pt progress bar with elapsed
/// and remaining, and previous / play-pause / next. Nothing playing: Platy and the words.
struct MediaBlock: View {
    let nowPlaying: NowPlaying
    var fixedNow: Date?

    static let nothingPlaying = "Nothing playing"

    /// `m:ss` (`h:mm:ss` from an hour).
    static func clock(_ seconds: TimeInterval) -> String {
        let total: Int = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ss: String = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }

    var body: some View {
        if let title = nowPlaying.title {
            playing(title: title)
        } else {
            HStack(spacing: 10) {
                PlatyView(mood: .idle, size: HomeMetrics.artSize)
                Text(verbatim: Self.nothingPlaying)
                    .font(DS.font(TypeScale.body))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: HomeMetrics.artSize, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    private func playing(title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 14) {
                art
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(DS.font(TypeScale.title))
                        .foregroundStyle(DS.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if let artist = nowPlaying.artist, !artist.isEmpty {
                        Text(verbatim: artist)
                            .font(DS.font(TypeScale.secondary))
                            .foregroundStyle(DS.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    progress.padding(.top, 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            controls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var art: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    DS.fill
                    Image(systemName: "music.note")
                        .font(.system(size: IconSize.header))
                        .foregroundStyle(DS.tertiary)
                }
            }
        }
        .frame(width: HomeMetrics.artSize, height: HomeMetrics.artSize)
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityHidden(true)
    }

    @ViewBuilder private var progress: some View {
        TickingNow(fixed: fixedNow) { now in
            if let clock = nowPlaying.clock, clock.duration > 0 {
                let fraction: Double = min(1, max(0, clock.progress(now: now)))
                VStack(spacing: 3) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.hairline)
                            Capsule().fill(DS.secondary).frame(width: g.size.width * fraction)
                        }
                    }
                    .frame(height: 3)
                    HStack {
                        Text(verbatim: Self.clock(clock.position(now: now)))
                        Spacer()
                        Text(verbatim: "-" + Self.clock(clock.remaining(now: now)))
                    }
                    .font(DS.font(TypeScale.caption).monospacedDigit())
                    .foregroundStyle(DS.tertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.clock(clock.position(now: now))) of \(Self.clock(clock.duration))")
            } else {
                Color.clear.frame(height: 3)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 0)
            button("backward.fill", "Previous", size: 12) { nowPlaying.previous() }
            button(nowPlaying.isPlaying ? "pause.fill" : "play.fill", nowPlaying.isPlaying ? "Pause" : "Play",
                   size: TypeScale.glyph.size) {
                nowPlaying.playPause()
            }
            button("forward.fill", "Next", size: 12) { nowPlaying.next() }
            Spacer(minLength: 0)
        }
    }

    private func button(_ symbol: String, _ label: String, size: CGFloat,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.primary)
        .accessibilityLabel(label)
        .help(label)
    }
}
