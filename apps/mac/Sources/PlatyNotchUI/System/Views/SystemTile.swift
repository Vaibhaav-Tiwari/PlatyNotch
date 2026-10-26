import PlatyNotchKit
import SwiftUI

/// The Today tile: battery (laptops only) and keep-awake, then the opt-in rows.
struct SystemTile: View {
    let widget: SystemWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let b = widget.battery {
                BatteryRow(state: b)
            }
            KeepAwakeRow(widget: widget)
            if widget.options.headphones {
                ForEach(widget.headphones) { h in HeadphonesRow(info: h) }
            }
            if widget.options.downloads {
                ForEach(widget.downloadsActive, id: \.path) { d in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.circle").foregroundStyle(Theme.tint(.accent)).frame(width: 22)
                            .accessibilityHidden(true)
                        Text(verbatim: d.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("Downloading").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let url = widget.finishedDownload {
                    FinishedDownloadRow(widget: widget, url: url)
                }
            }
        }
        .onAppear { widget.refreshHeadphones() }
    }
}

struct HeadphonesRow: View {
    let info: HeadphonesInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: HeadphonesText.symbol(info.name)).frame(width: 22).accessibilityHidden(true)
            Text(verbatim: info.name).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            if let summary = info.battery.summary {
                Text(verbatim: summary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum HeadphonesText {
    static func symbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        return "headphones"
    }
}

/// The last finished download with its buttons (in the tile).
struct FinishedDownloadRow: View {
    let widget: SystemWidget
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.tint(.accent)).frame(width: 22)
                .accessibilityHidden(true)
            Text(verbatim: url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            DownloadButtons(widget: widget, compact: true)
        }
    }
}

/// Open, Show in Finder and (shelf on) Add to Shelf: the only ways a download is acted on.
struct DownloadButtons: View {
    let widget: SystemWidget
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            Button("Open") { widget.openDownload() }
            Button(compact ? "Show" : "Show in Finder") { widget.revealDownload() }
                .accessibilityLabel("Show in Finder")
            if widget.canMoveToShelf {
                Button(compact ? "Shelf" : "Add to Shelf") { widget.addDownloadToShelf() }
                    .accessibilityLabel("Add to Shelf")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
    }
}

/// The finished-download notice below the notch (`PanelLayout.widgetPeekHeight`).
struct DownloadPeekView: View {
    let widget: SystemWidget
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.tint(.accent))
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloaded").font(.system(size: 13, weight: .semibold))
                    Text(verbatim: url.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack {
                Spacer(minLength: 0)
                DownloadButtons(widget: widget)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// "AirPods Pro connected" with the battery when macOS reports it.
struct HeadphonesPeekView: View {
    let info: HeadphonesInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: HeadphonesText.symbol(info.name))
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: info.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(info.battery.summary.map { "Connected · \($0)" } ?? "Connected")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

struct BatteryRow: View {
    let state: BatteryState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.symbolName)
                .foregroundStyle(state.isLow ? Theme.tint(.critical) : state.pluggedIn ? Theme.tint(.accent) : .primary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(verbatim: "\(state.percent)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            Text(state.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Keep awake: a menu of durations; while on, the time left (ticking only while the tile
/// is on screen) and Stop.
struct KeepAwakeRow: View {
    let widget: SystemWidget

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: widget.keepAwake.session == nil ? "cup.and.saucer" : "cup.and.saucer.fill")
                .foregroundStyle(widget.keepAwake.session == nil ? Color.secondary : Theme.tint(.accent))
                .frame(width: 22)
                .accessibilityHidden(true)
            if let s = widget.keepAwake.session {
                if let until = s.until {
                    TimelineView(.periodic(from: s.startedAt, by: 1)) { ctx in
                        Text("Awake · \(TodayFormat.clock(until.timeIntervalSince(ctx.date))) left")
                            .font(.system(size: 12)).monospacedDigit()
                    }
                } else {
                    Text("Awake until turned off").font(.system(size: 12))
                }
                Spacer(minLength: 4)
                durationMenu(title: "Change")
                Button("Stop") { widget.stopKeepAwake() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            } else {
                Text("Keep awake").font(.system(size: 12))
                Spacer(minLength: 4)
                durationMenu(title: "Start")
            }
        }
        if let error = widget.keepAwake.lastError {
            Text(error).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
        }
    }

    private func durationMenu(title: String) -> some View {
        Menu(title) {
            ForEach(KeepAwakeDuration.allCases, id: \.self) { d in
                Button(d.label) { widget.startKeepAwake(d) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 11))
        .accessibilityLabel(title == "Start" ? "Keep awake for" : "Change keep-awake time")
    }
}

/// System as a Library tool on a Mac without a battery: Keep awake leads, with its symbol,
/// one line and Start (a menu of durations); while on, the time left, Change and Stop.
/// The opt-in rows (headphones, downloads) follow on a card when there are any.
struct KeepAwakeToolPage: View {
    let widget: SystemWidget

    var body: some View {
        let session = widget.keepAwake.session
        ToolIconPage(systemImage: session == nil ? "cup.and.saucer" : "cup.and.saucer.fill",
                     title: session == nil ? "Keep awake" : "Awake",
                     detail: session == nil ? "Keeps your Mac from sleeping for as long as you choose." : "") {
            VStack(spacing: Space.m) {
                if let s = session {
                    if let until = s.until {
                        TimelineView(.periodic(from: s.startedAt, by: 1)) { ctx in
                            Text(verbatim: "\(TodayFormat.clock(until.timeIntervalSince(ctx.date))) left")
                                .font(DS.font(TypeScale.title))
                                .monospacedDigit()
                        }
                    } else {
                        Text("Until turned off").font(DS.font(TypeScale.title))
                    }
                    Button("Stop") { widget.stopKeepAwake() }
                        .buttonStyle(ToolPrimaryButtonStyle())
                } else {
                    CapsuleSegments(selection: $duration,
                                    options: KeepAwakeDuration.allCases.map { ($0, Self.short($0)) },
                                    label: "Keep awake for", size: TypeScale.body.size)
                        .fixedSize()
                    Button("Start") { widget.startKeepAwake(duration) }
                        .buttonStyle(ToolPrimaryButtonStyle())
                        .accessibilityLabel("Keep awake for \(duration.label)")
                }
                if let error = widget.keepAwake.lastError {
                    Text(error).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
                }
                if hasExtras {
                    ToolControlCard {
                        if widget.options.headphones {
                            ForEach(widget.headphones) { h in HeadphonesRow(info: h) }
                        }
                        if widget.options.downloads {
                            if let url = widget.finishedDownload { FinishedDownloadRow(widget: widget, url: url) }
                        }
                    }
                }
            }
        }
        .onAppear { widget.refreshHeadphones() }
    }

    private var hasExtras: Bool {
        (widget.options.headphones && !widget.headphones.isEmpty)
            || (widget.options.downloads && widget.finishedDownload != nil)
    }

    @State private var duration: KeepAwakeDuration = .oneHour

    static func short(_ d: KeepAwakeDuration) -> String {
        switch d {
        case .thirtyMinutes: "30 min"
        case .oneHour: "1 hour"
        case .twoHours: "2 hours"
        case .untilOff: "Until off"
        }
    }
}

/// The plug-in / unplug peek below the notch (`PanelLayout.widgetPeekHeight`).
struct PowerPeekView: View {
    let peek: SystemWidget.PowerPeek

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: peek.change == .pluggedIn ? "bolt.fill" : peek.state.symbolName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(peek.change == .pluggedIn ? Theme.tint(.accent)
                                 : peek.state.isLow ? Theme.tint(.critical) : .primary)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(peek.change == .pluggedIn ? "Plugged in" : "On battery")
                    .font(.system(size: 13, weight: .semibold))
                Text(peek.state.statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(verbatim: "\(peek.state.percent)%")
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Widgets › System.
struct SystemSettings: View {
    let widget: SystemWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsNote("Battery: a peek with the percent when you plug in or unplug, and the pill shows low battery "
                 + "(10% or less) and charging. Keep awake: stops the display sleeping for the time you pick; "
                 + "it ends when the time is up, when you turn this widget off, or when you quit. "
                 + "Neither needs a permission.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HeadphonesSettings(widget: widget)
            Divider()
            DownloadsSettings(widget: widget)
        }
    }
}

/// The headphones button: the only place the Bluetooth prompt can appear.
struct HeadphonesSettings: View {
    let widget: SystemWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("AirPods and headphones", systemImage: "airpods")
                Spacer()
                if widget.options.headphones {
                    if widget.headphonesNeedAccess {
                        if widget.bluetoothAccess == .denied {
                            Button("Open System Settings") { Permissions.open(.bluetooth) }
                        } else {
                            Button("Allow Bluetooth…") { widget.requestHeadphonesAccess() }
                        }
                    }
                    Button("Turn Off") { widget.setHeadphones(false) }
                } else {
                    Button("Turn On…") { widget.setHeadphones(true) }
                }
            }
            Text(status)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: String {
        guard widget.options.headphones else {
            return "Off. Turning it on asks for Bluetooth access, to show a peek when AirPods or other headphones "
                + "connect, with their battery when macOS reports it. PlatyNotch never pairs or connects devices."
        }
        if widget.headphonesNeedAccess {
            return widget.bluetoothAccess == .denied
                ? "Bluetooth access is off for PlatyNotch (System Settings › Privacy & Security › Bluetooth)."
                : "Waiting for Bluetooth access."
        }
        return widget.headphones.isEmpty ? "On. No headphones connected." : "On."
    }
}

/// The downloads button: the only place the Downloads-folder prompt can appear.
struct DownloadsSettings: View {
    let widget: SystemWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                Spacer()
                buttons
            }
            if widget.options.downloads {
                folderRow
            }
            if let why = widget.extraFolderRejection {
                Text(why).font(DS.font(TypeScale.caption)).foregroundStyle(Theme.tint(.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(status)
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        if widget.options.downloads {
            Button("Turn Off") { widget.setDownloads(false) }
        } else if widget.downloadsAsking {
            ProgressView().controlSize(.small)
        } else {
            if widget.downloadsDenied {
                Button("Open System Settings") { Permissions.open(.filesAndFolders) }
            }
            Button(turnOnTitle) { widget.setDownloads(true) }
        }
    }

    private var turnOnTitle: String {
        if widget.options.downloadsNeedReenable { return "Turn On Again…" }
        return widget.downloadsDenied ? "Try Again" : "Turn On…"
    }

    private var folderRow: some View {
        HStack {
            Text(folderText).font(DS.font(TypeScale.caption)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(widget.options.extraFolder == nil ? "Add a Folder…" : "Change…") { chooseFolder() }
            if widget.options.extraFolder != nil {
                Button("Remove") { widget.setExtraFolder(nil) }
            }
        }
    }

    private var folderText: String {
        guard let extra = widget.options.extraFolder else { return "Watching ~/Downloads" }
        return "Also watching " + (extra as NSString).abbreviatingWithTildeInPath
    }

    private var status: String {
        if widget.downloadsAsking { return "Waiting for macOS to allow the Downloads folder." }
        if widget.options.downloadsNeedReenable {
            return "Turn on again (PlatyNotch was updated or reinstalled): macOS may need to ask once more."
        }
        if widget.downloadsDenied {
            return "macOS did not allow PlatyNotch to see your Downloads folder (System Settings › Privacy & "
                + "Security › Files and Folders). Downloads stay off."
        }
        return "Shows a download in progress in the pill and a notice when it finishes, with Open, Show in "
            + "Finder and Add to Shelf (when the shelf is on). Turning it on asks to see your Downloads folder. "
            + "Only file names and sizes are read, never contents, and nothing happens to a file unless you click. "
            + "A second folder must not be on the Desktop, in Documents, iCloud Drive or on an external drive."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose a second folder your browser saves downloads to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The path as chosen is checked first (a rejected one records why); it is resolved
        // (symlinks) only when allowed, and the resolved path is checked again.
        if case .rejected = WatchFolderPolicy.check(url.path, home: widget.downloads.home) {
            widget.setExtraFolder(url.path)
            return
        }
        widget.setExtraFolder(DownloadsMonitor.canonical(url.path))
    }
}
