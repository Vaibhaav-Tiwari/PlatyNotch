import PlatyNotchKit
import SwiftUI

/// What the sky part of the Today card shows (Island spec 3.2, 3.5).
enum SkyContent: Equatable {
    /// A reading: the condition's sky and symbol, "22°", "Sunny · Bengaluru", one useful line.
    case reading(sky: WeatherSky, symbol: String, temperature: String, condition: String, detail: String?)
    /// No place and no Location access: "Use my location" (only with `offerLocation`) and "Add a city".
    case empty(offerLocation: Bool)
    /// A place, no reading yet.
    case loading

    static let title = "Weather"
    static let useMyLocation = "Use my location"
    static let addCity = "Add a city"
    static let loadingText = "Loading weather…"
    /// The empty and loading states' sky.
    static let placeholderSky = WeatherSky.of(.clouds, isDay: true)

    /// The sky for `weather` (nil: the widget is off, no sky at all).
    @MainActor
    static func of(_ weather: WeatherWidget?, now: Date, calendar: Calendar = .current,
                   locale: Locale = .current) -> SkyContent? {
        guard let weather else { return nil }
        if weather.locating { return .loading }
        switch weather.source {
        case .needsPermission: return .empty(offerLocation: true)
        case .needsCity: return .empty(offerLocation: false)
        case .place(_, _, let name):
            guard let w = weather.weather else { return .loading }
            return .reading(sky: WeatherSky.of(w), symbol: WeatherCode.describe(w.code, isDay: w.isDay).symbol,
                            temperature: WeatherFormat.temperature(w.temperatureC, unit: weather.unit),
                            condition: WeatherLine.condition(w, place: name),
                            detail: WeatherLine.detail(w, unit: weather.unit, fetchedAt: weather.fetchedAt, now: now,
                                                       calendar: calendar, locale: locale))
        }
    }

    var texts: [String] {
        switch self {
        case .reading(_, _, let t, let c, let d): [t, c] + (d.map { [$0] } ?? [])
        case .empty(let offer): [Self.title] + (offer ? [Self.useMyLocation] : []) + [Self.addCity]
        case .loading: [Self.title, Self.loadingText]
        }
    }

    var sky: WeatherSky {
        if case .reading(let sky, _, _, _, _) = self { return sky }
        return Self.placeholderSky
    }
}

/// Home's Today card (Island spec 3.2): the weather painted as the sky on top, a white 0.06
/// hairline, then the next event or the week strip. With the weather widget off, the next
/// part fills the card.
struct TodayCard: View {
    let weather: WeatherWidget?
    let next: TodayNext
    var fixedNow: Date?
    /// "Connect Calendar": Settings › Privacy.
    var onConnectCalendar: () -> Void = {}
    @Environment(\.panelTicking) private var ticking
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Every string the card shows, sky first (tests). `sky` nil: no sky part.
    static func texts(sky: [String]?, next: TodayNext) -> [String] {
        (sky ?? []) + next.texts
    }

    var body: some View {
        let sky: SkyContent? = SkyContent.of(weather, now: fixedNow ?? Date())
        VStack(alignment: .leading, spacing: 0) {
            if let sky {
                skyPart(sky)
                Rectangle().fill(DS.hairline).frame(height: 1).accessibilityHidden(true)
            }
            nextPart(fill: sky == nil)
                .padding(.horizontal, 14)
                .padding(.top, sky == nil ? HomeMetrics.cardPadding : 8)
                .padding(.bottom, 10)
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DS.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.island, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Today")
    }

    // MARK: - Sky

    private func skyPart(_ content: SkyContent) -> some View {
        ZStack(alignment: .topLeading) {
            WeatherSkyView(sky: content.sky, animating: ticking && !reduceMotion)
                .clipped()
                .accessibilityHidden(true)
            skyText(content)
                .padding(.top, HomeMetrics.cardPadding)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func skyText(_ content: SkyContent) -> some View {
        switch content {
        case .reading(_, let symbol, let temperature, let condition, let detail):
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: temperature)
                        .font(DS.font(TypeScale.temperature).monospacedDigit())
                        .tracking(-0.6)
                        .foregroundStyle(Color.white)
                        .padding(.bottom, 2)
                    Text(verbatim: condition)
                        .font(DS.font(TypeScale.secondary).weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1).truncationMode(.tail)
                    if let detail {
                        Text(verbatim: detail)
                            .font(DS.font(TypeScale.caption))
                            .foregroundStyle(Color.white.opacity(0.78))
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: HomeMetrics.weatherSymbol * 0.8))
                    .frame(width: HomeMetrics.weatherSymbol, height: HomeMetrics.weatherSymbol)
                    .padding(.top, -2)
                    .accessibilityHidden(true)
            }
            .accessibilityElement(children: .combine)
        case .empty(let offerLocation):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "cloud.sun.fill").symbolRenderingMode(.multicolor)
                        .font(.system(size: IconSize.header))
                    Text(verbatim: SkyContent.title)
                        .font(DS.font(TypeScale.title))
                }
                .foregroundStyle(Color.white)
                Text("See the sky where you are.")
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(Color.white.opacity(0.78))
                HStack(spacing: 6) {
                    if offerLocation {
                        skyButton(SkyContent.useMyLocation, symbol: "location.fill", primary: true) {
                            Task { await weather?.useMyLocation() }
                        }
                    }
                    skyButton(SkyContent.addCity, symbol: nil, primary: !offerLocation) { weather?.onOpenSettings?() }
                }
            }
        case .loading:
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: SkyContent.title)
                    .font(DS.font(TypeScale.title))
                    .foregroundStyle(Color.white)
                Text(verbatim: SkyContent.loadingText)
                    .font(DS.font(TypeScale.secondary))
                    .foregroundStyle(Color.white.opacity(0.78))
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        }
    }

    private func skyButton(_ title: String, symbol: String?, primary: Bool,
                           _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11)) }
                Text(verbatim: title).lineLimit(1)
            }
            .font(DS.font(TypeScale.secondary).weight(.semibold))
            .foregroundStyle(primary ? Color.black : Color.white)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(primary ? Color.white.opacity(0.94) : Color.white.opacity(0.18), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Next

    @ViewBuilder private func nextPart(fill: Bool) -> some View {
        switch next {
        case .event(let label, let title, let detail):
            VStack(alignment: .leading, spacing: 1) {
                caption(label)
                Text(verbatim: title)
                    .font(DS.font(TypeScale.body).weight(.semibold))
                    .foregroundStyle(DS.primary)
                    .lineLimit(fill ? 2 : 1).truncationMode(.tail)
                    .padding(.top, 1)
                Text(verbatim: detail)
                    .font(DS.font(TypeScale.secondary))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
        case .free(let label, let days):
            VStack(alignment: .leading, spacing: 4) {
                caption(label)
                WeekStrip(days: days)
            }
        case .noCalendar(let days):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    caption(TodayNext.thisWeek)
                    Spacer(minLength: 4)
                    Button(action: onConnectCalendar) {
                        HStack(spacing: 2) {
                            Text(verbatim: TodayNext.connectCalendar)
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                        }
                        .font(DS.font(TypeScale.caption).weight(.medium))
                        .foregroundStyle(DS.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Settings › Privacy & Permissions")
                }
                WeekStrip(days: days)
            }
        case .sample(let title, let subtitle):
            VStack(alignment: .leading, spacing: 2) {
                caption("Try it")
                Text(verbatim: title)
                    .font(DS.font(TypeScale.body).weight(.semibold))
                    .foregroundStyle(DS.primary)
                Text(verbatim: subtitle)
                    .font(DS.font(TypeScale.secondary))
                    .foregroundStyle(DS.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(verbatim: text)
            .font(DS.font(TypeScale.caption))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(DS.tertiary)
            .lineLimit(1)
    }
}
