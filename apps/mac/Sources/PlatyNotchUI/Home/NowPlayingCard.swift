import AppKit
import PlatyNotchKit
import SwiftUI

/// Home's Now Playing card (Island spec 3.1, 3.5). Playing or paused: 74 pt art with the
/// source app's badge, title, "Artist · Album", a 4 pt progress bar with elapsed and
/// remaining, and previous / play-pause / next, over the art's own colour glowing softly
/// behind the card's left half. Nothing playing: Resume and recents, Platy and a greeting;
/// never an empty box.
struct NowPlayingCard: View {
    let nowPlaying: NowPlaying
    var recents: [String] = []
    var fixedNow: Date?

    /// The card's width in the 640 pt panel (Now Playing : Today = 1.25 : 1, 10 apart); the
    /// fitting width never grows past it, however long the title.
    nonisolated static let idealWidth: CGFloat = {
        let room: CGFloat = HomeMetrics.panelWidth - 2 * Space.panelSide - HomeMetrics.cardGap
        return room * HomeMetrics.nowPlayingRatio / (HomeMetrics.nowPlayingRatio + 1)
    }()

    // MARK: - Seams

    /// `m:ss` (`h:mm:ss` from an hour).
    static func clock(_ seconds: TimeInterval) -> String {
        let total: Int = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        let ss: String = s < 10 ? "0\(s)" : "\(s)"
        if h > 0 { return "\(h):\(m < 10 ? "0\(m)" : "\(m)"):\(ss)" }
        return "\(m):\(ss)"
    }

    /// "Artist · Album" (either alone when the other is missing).
    static func subtitle(_ np: NowPlaying) -> String? {
        let parts = [np.artist, np.info?.album].compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Every string the card shows (tests).
    static func texts(_ np: NowPlaying, empty: MusicEmptyState?) -> [String] {
        if let title = np.title {
            var out = [title]
            if let sub = subtitle(np) { out.append(sub) }
            if let clock = np.clock, clock.duration > 0 {
                let now = Date()
                out.append(Self.clock(clock.position(now: now)))
                out.append("-" + Self.clock(clock.remaining(now: now)))
            }
            return out
        }
        guard let empty else { return [] }
        var out = [empty.caption]
        if let resume = empty.resume { out.append(resume) }
        out += empty.recents
        out.append(empty.greeting)
        if let hint = empty.hint { out.append(hint) }
        return out
    }

    /// The glow: the art's dominant colour, or `DominantColor.fallback` for missing or
    /// monochrome art (never black on black).
    static func glowColor(tint: RGB?) -> RGB {
        guard let tint, !tint.isMonochrome else { return RGB(DominantColor.fallback) }
        return tint
    }

    /// The source-app badge needs the app's installed icon: no icon, no badge (never initials).
    static func showsSourceBadge(_ np: NowPlaying) -> Bool { np.appIcon != nil }

    // MARK: - Body

    var body: some View {
        content
            .padding(HomeMetrics.cardPadding)
            .frame(idealWidth: Self.idealWidth, maxWidth: .infinity, maxHeight: .infinity,
                   alignment: nowPlaying.title == nil ? .topLeading : .leading)
            .background { background }
            .clipShape(RoundedRectangle(cornerRadius: Radius.island, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now Playing")
    }

    @ViewBuilder private var content: some View {
        if let title = nowPlaying.title {
            playing(title: title)
        } else {
            nothingPlaying(empty)
        }
    }

    private var empty: MusicEmptyState {
        let hour: Int = Calendar.current.component(.hour, from: fixedNow ?? Date())
        return MusicEmptyState.make(last: nowPlaying.lastPlayed, recents: recents, hour: hour)
    }

    private var background: some View {
        ZStack {
            DS.card
            if nowPlaying.title != nil {
                glow.id(glowKey).transition(.opacity)
            }
        }
        // Keyed on the colour too: the album colour arrives after the title, and fades in.
        .animation(.easeInOut(duration: 0.6), value: glowKey)
    }

    private var glowKey: String {
        let c = Self.glowColor(tint: nowPlaying.artworkRGB)
        return "\(nowPlaying.title ?? "")|\(c.r),\(c.g),\(c.b)"
    }

    /// The art's colour as a soft ellipse behind the left half (spec 3.1: an ellipse blurred
    /// 34 pt at 0.45), clipped by the card. Drawn as an elliptical gradient that falls off over
    /// the blur's width: the same look with no blur filter (cheaper, and it renders the same in
    /// snapshots).
    private var glow: some View {
        GeometryReader { g in
            let color = Color(Self.glowColor(tint: nowPlaying.artworkRGB))
            let blur: CGFloat = HomeMetrics.glowBlur
            Ellipse()
                .fill(EllipticalGradient(stops: [
                    .init(color: color, location: 0),
                    .init(color: color.opacity(0.75), location: 0.4),
                    .init(color: color.opacity(0.3), location: 0.72),
                    .init(color: color.opacity(0), location: 1),
                ]))
                // The wireframe's ellipse (x −20%…60%, y −40%…140%) grown by the blur on each side.
                .frame(width: g.size.width * 0.8 + 2 * blur, height: g.size.height * 1.8 + 2 * blur)
                .position(x: g.size.width * 0.2, y: g.size.height * 0.5)
                .opacity(HomeMetrics.glowOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Playing

    private func playing(title: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            art
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title)
                    .font(DS.font(TypeScale.title))
                    .foregroundStyle(DS.primary)
                    .lineLimit(1).truncationMode(.tail)
                if let sub = Self.subtitle(nowPlaying) {
                    Text(verbatim: sub)
                        .font(DS.font(TypeScale.secondary))
                        .foregroundStyle(DS.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.top, 1)
                }
                progress.padding(.top, 9)
                controls.padding(.top, 4)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var art: some View {
        Group {
            if let image = nowPlaying.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    DS.raised
                    Image(systemName: "music.note")
                        .font(.system(size: HomeMetrics.playGlyph, weight: .medium))
                        .foregroundStyle(DS.tertiary)
                }
            }
        }
        .frame(width: HomeMetrics.artSize, height: HomeMetrics.artSize)
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(alignment: .bottomTrailing) { sourceBadge }
        .accessibilityHidden(true)
    }

    /// The playing app's icon, 4 pt past the art's corner, ringed in the card colour.
    @ViewBuilder private var sourceBadge: some View {
        if Self.showsSourceBadge(nowPlaying), let icon = nowPlaying.appIcon {
            let ring: CGFloat = HomeMetrics.sourceBadgeBorder
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: HomeMetrics.sourceBadge, height: HomeMetrics.sourceBadge)
                .padding(ring)
                .background(DS.card, in: RoundedRectangle(cornerRadius: Radius.small + ring, style: .continuous))
                .offset(x: 4 + ring, y: 4 + ring)
                .help(nowPlaying.appName ?? "")
        }
    }

    @ViewBuilder private var progress: some View {
        TickingNow(fixed: fixedNow) { now in
            if let clock = nowPlaying.clock, clock.duration > 0 {
                let fraction: Double = min(1, max(0, clock.progress(now: now)))
                VStack(spacing: 3) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule().fill(DS.primary).frame(width: g.size.width * fraction)
                        }
                    }
                    .frame(height: HomeMetrics.progressHeight)
                    HStack {
                        Text(verbatim: Self.clock(clock.position(now: now)))
                        Spacer(minLength: 8)
                        Text(verbatim: "-" + Self.clock(clock.remaining(now: now)))
                    }
                    .font(DS.font(TypeScale.caption).monospacedDigit())
                    .foregroundStyle(DS.tertiary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Self.clock(clock.position(now: now))) of \(Self.clock(clock.duration))")
            } else {
                Capsule().fill(Color.white.opacity(0.14)).frame(height: HomeMetrics.progressHeight)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            control("backward.fill", "Previous", size: HomeMetrics.skipGlyph) { nowPlaying.previous() }
            control(nowPlaying.isPlaying ? "pause.fill" : "play.fill", nowPlaying.isPlaying ? "Pause" : "Play",
                    size: HomeMetrics.playGlyph) { nowPlaying.playPause() }
            control("forward.fill", "Next", size: HomeMetrics.skipGlyph) { nowPlaying.next() }
        }
    }

    private func control(_ symbol: String, _ label: String, size: CGFloat, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(height: HomeMetrics.playGlyph + 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DS.primary)
        .accessibilityLabel(label)
        .help(label)
    }

    // MARK: - Nothing playing

    private func nothingPlaying(_ e: MusicEmptyState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: e.caption)
                .font(DS.font(TypeScale.caption))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(DS.tertiary)
            if let resume = e.resume {
                ChipFlow(spacing: 8) {
                    Button { nowPlaying.resume() } label: {
                        HStack(spacing: 6) {
                            if let icon = nowPlaying.lastPlayedIcon {
                                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 14, height: 14)
                            } else {
                                Image(systemName: "play.fill").font(.system(size: 11))
                            }
                            Text(verbatim: resume).lineLimit(1).truncationMode(.tail)
                        }
                        .chip()
                    }
                    .buttonStyle(.plain)
                    .help("Play in \(nowPlaying.lastPlayed.map(\.bundleID).map(Self.appName) ?? "the last app")")
                    ForEach(e.recents, id: \.self) { name in
                        Button { nowPlaying.playRecent(name) } label: {
                            Text(verbatim: name).lineLimit(1).truncationMode(.tail).chip()
                        }
                        .buttonStyle(.plain)
                        .help("Play \(name) in Music")
                    }
                }
            }
            if e.resume == nil {
                // Never played: Platy larger, in the middle of the card.
                Spacer(minLength: 4)
                greeting(e, platy: 44)
                Spacer(minLength: 0)
            } else {
                greeting(e, platy: 30)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: nowPlaying.lastPlayed?.bundleID) { await nowPlaying.refreshRecents() }
    }

    private func greeting(_ e: MusicEmptyState, platy: CGFloat) -> some View {
        HStack(spacing: 10) {
            PlatyView(mood: .idle, size: platy)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: e.greeting)
                    .font(DS.font(TypeScale.secondary))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(2)
                if let hint = e.hint {
                    Text(verbatim: hint)
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(DS.tertiary)
                        .lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return "the last app" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

extension View {
    /// Island's chip: 12 pt primary text on a `raised` capsule.
    func chip() -> some View {
        font(DS.font(TypeScale.secondary))
            .foregroundStyle(DS.primary)
            .padding(.vertical, 5)
            .padding(.horizontal, 11)
            .background(DS.raised, in: Capsule())
    }
}

/// Chips left to right, wrapping to a new line when the next one does not fit; a chip
/// wider than the line is narrowed (it truncates).
struct ChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width, subviews: subviews)
        let height: CGFloat = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width: CGFloat = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y: CGFloat = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x: CGFloat = bounds.minX
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [(index: Int, size: CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat?, subviews: Subviews) -> [Row] {
        let limit: CGFloat = width ?? NowPlayingCard.idealWidth - 2 * HomeMetrics.cardPadding
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > limit { size = view.sizeThatFits(ProposedViewSize(width: limit, height: nil)) }
            let needed: CGFloat = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > limit, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((i, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
