import AppKit
import PlatyNotchKit
import SwiftUI

/// The weather tile: conditions, temperature, the next likely rain, and the data's age
/// when it is old or could not be refreshed.
struct WeatherTile: View {
    let widget: WeatherWidget

    var body: some View {
        if let place = widget.place {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                content(place: place, now: ctx.date)
            }
        } else {
            Label("Choose a city in Settings › Widgets › Weather", systemImage: "cloud.sun")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func content(place: GeoPlace, now: Date) -> some View {
        if let w = widget.weather {
            let d = WeatherCode.describe(w.code, isDay: w.isDay)
            HStack(spacing: 10) {
                Image(systemName: d.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 22))
                    .frame(width: 30)
                    .accessibilityHidden(true)
                Text(WeatherFormat.temperature(w.temperatureC, unit: widget.unit))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "\(d.text) · \(place.name)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(rain(w)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    if let note = widget.ageNote(at: now) {
                        Text(verbatim: note).font(DS.font(TypeScale.caption)).foregroundStyle(Theme.tint(.warning)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .panelFill()
            .accessibilityElement(children: .combine)
        } else if let error = widget.lastError {
            Label("\(error). Trying again soon.", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else if widget.offline {
            Label("Offline: weather for \(place.name) loads when you are back online.", systemImage: "wifi.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        } else {
            Label("Loading weather for \(place.name)…", systemImage: "cloud.sun")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func rain(_ w: WeatherNow) -> String {
        guard let next = w.nextRain else { return "No rain expected in the next 12 h" }
        if next <= w.time { return "Rain likely now" }
        let f = DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: w.utcOffsetSeconds)
        f.setLocalizedDateFormatFromTemplate("j")
        return "Rain likely around \(f.string(from: next))"
    }
}

/// Settings › Widgets › Weather: the city, the unit and what is sent where.
struct WeatherSettings: View {
    @Bindable var widget: WeatherWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let place = widget.place {
                HStack {
                    Text("City")
                    Spacer()
                    Text(verbatim: place.displayName).foregroundStyle(.secondary)
                    Button("Remove") { widget.clearPlace() }
                }
            }
            HStack {
                TextField(text: $widget.query, prompt: Text(widget.place == nil ? "e.g. Lisbon" : "Change city")) {
                    Text("City")
                }
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit { widget.search() }
                Button("Search") { widget.search() }
                    .disabled(widget.searching || widget.query.trimmingCharacters(in: .whitespaces).count < 2)
                if widget.searching { ProgressView().controlSize(.small) }
            }
            if let message = widget.searchMessage {
                Text(verbatim: message).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
            }
            ForEach(widget.results) { p in
                HStack {
                    Text(verbatim: p.displayName).lineLimit(1)
                    Spacer()
                    Button("Choose") { widget.choose(p) }
                }
                .padding(.leading, 8)
            }
            Picker("Temperature", selection: $widget.unit) {
                Text("°C").tag(TemperatureUnit.celsius)
                Text("°F").tag(TemperatureUnit.fahrenheit)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
            SettingsNote("Weather data by Open-Meteo.com. Search sends the city name you type to Open-Meteo's geocoding service; "
                 + "the forecast request carries only the chosen place's coordinates, rounded to about a kilometre. "
                 + "No location access, account, cookies or tracking. Refreshes every 30 minutes while this widget is on, "
                 + "never while the Mac sleeps or is offline.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
