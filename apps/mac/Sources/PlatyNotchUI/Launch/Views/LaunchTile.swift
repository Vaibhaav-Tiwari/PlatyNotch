import AppKit
import PlatyNotchKit
import SwiftUI

/// Today tile: pinned sites as icons (click opens), pinned Shortcuts as buttons (click
/// runs), "Add current tab" and the Shortcuts picker, and the last notice.
struct LaunchTile: View {
    let widget: LaunchWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if widget.pins.sites.isEmpty && widget.pins.shortcuts.isEmpty {
                Text("Pin sites with Add current tab or in Settings › Widgets, and Shortcuts from the list.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !widget.pins.sites.isEmpty { SiteGrid(widget: widget) }
            if !widget.pins.shortcuts.isEmpty { ShortcutRow(widget: widget) }
            if widget.pickerOpen { ShortcutPicker(widget: widget) }
            if let notice = widget.notice { NoticeLine(notice: notice) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Sites & Shortcuts", systemImage: "square.grid.2x2")
                .font(.system(size: 12, weight: .semibold))
            Spacer(minLength: 0)
            AddTabButton(widget: widget)
            Button {
                if widget.pickerOpen { widget.closePicker() } else { widget.openPicker() }
            } label: {
                Image(systemName: "bolt.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Pin a shortcut")
            .accessibilityLabel(widget.pickerOpen ? "Close the shortcuts list" : "Pin a shortcut")
        }
    }
}

/// The only control that can make macOS ask about controlling a browser.
struct AddTabButton: View {
    let widget: LaunchWidget

    var body: some View {
        Button {
            widget.addCurrentTab()
        } label: {
            if widget.readingTab {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
        }
        .buttonStyle(.borderless)
        .disabled(widget.readingTab || widget.isFull)
        .help("Pin the current tab of Safari, Chrome or Arc")
        .accessibilityLabel("Add current tab")
    }
}

private struct SiteGrid: View {
    let widget: LaunchWidget
    private let columns = Array(repeating: GridItem(.fixed(48), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(widget.pins.sites) { site in
                SiteButton(widget: widget, site: site)
            }
        }
    }
}

private struct SiteButton: View {
    let widget: LaunchWidget
    let site: PinnedSite

    var body: some View {
        Button { widget.open(site) } label: {
            VStack(spacing: 3) {
                SiteIcon(image: widget.icon(for: site), letter: SiteURL.letter(for: site), size: 26)
                Text(verbatim: site.title)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 48)
            }
        }
        .buttonStyle(.plain)
        .help(site.url.absoluteString)
        .accessibilityLabel("Open \(site.title)")
        .contextMenu {
            Button("Move Left") { widget.move(site, by: -1) }
            Button("Move Right") { widget.move(site, by: 1) }
            Divider()
            Button("Unpin \(site.title)") { widget.remove(site) }
        }
    }
}

/// A favicon, or the site's first letter on a tinted square.
struct SiteIcon: View {
    let image: NSImage?
    let letter: String
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Text(verbatim: letter)
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Theme.tint(.accent).opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

private struct ShortcutRow: View {
    let widget: LaunchWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(widget.pins.shortcuts) { shortcut in
                ShortcutButton(widget: widget, shortcut: shortcut)
            }
        }
    }
}

private struct ShortcutButton: View {
    let widget: LaunchWidget
    let shortcut: PinnedShortcut

    private var isRunning: Bool { widget.runningShortcut == shortcut.id }

    var body: some View {
        HStack(spacing: 6) {
            Button { widget.run(shortcut) } label: {
                Label(shortcut.name, systemImage: isRunning ? "hourglass" : "bolt.fill")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .disabled(widget.runningShortcut != nil)
            .accessibilityLabel("Run \(shortcut.name)")
            .contextMenu {
                Button("Unpin \(shortcut.name)") { widget.remove(shortcut) }
            }
            if isRunning {
                ProgressView().controlSize(.mini)
                Button("Cancel") { widget.cancelShortcut() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
            Spacer(minLength: 0)
        }
    }
}

/// The shortcuts list (`shortcuts list` ran when it opened): click one to pin it.
private struct ShortcutPicker: View {
    let widget: LaunchWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if widget.listing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Listing your shortcuts…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let message = widget.listMessage {
                Text(verbatim: message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let names = widget.available, !names.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(names, id: \.self) { name in
                            PickerRow(widget: widget, name: name)
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct PickerRow: View {
    let widget: LaunchWidget
    let name: String

    private var pinned: Bool { widget.pins.shortcuts.contains { $0.name == name } }

    var body: some View {
        Button { widget.pinShortcut(name) } label: {
            HStack {
                Text(verbatim: name).font(.system(size: 11)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 10))
            }
        }
        .buttonStyle(.plain)
        .disabled(pinned)
        .accessibilityLabel(pinned ? "\(name), pinned" : "Pin \(name)")
    }
}

private struct NoticeLine: View {
    let notice: LaunchNotice

    var body: some View {
        Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(notice.isError ? Theme.tint(.warning) : Color.secondary)
            .lineLimit(2)
    }
}

/// The peek after a shortcut finishes (done, or failed with its exit code).
struct LaunchResultPeek: View {
    let notice: LaunchNotice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(notice.isError ? Theme.tint(.warning) : Theme.tint(.accent))
                .accessibilityHidden(true)
            Text(verbatim: notice.text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .accessibilityElement(children: .combine)
    }
}

/// Settings › Widgets › Sites & Shortcuts: type an address, the pinned lists, and what is
/// sent where.
struct LaunchSettings: View {
    @Bindable var widget: LaunchWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("https://example.com", text: $widget.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { widget.addAddress() }
                Button("Pin") { widget.addAddress() }
                    .disabled(widget.isFull)
                Button("Add Current Tab") { widget.addCurrentTab() }
                    .disabled(widget.readingTab || widget.isFull)
            }
            Text(verbatim: countsText)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(widget.pins.sites) { site in
                PinnedSiteRow(widget: widget, site: site)
            }
            ForEach(widget.pins.shortcuts) { shortcut in
                PinnedShortcutRow(widget: widget, shortcut: shortcut)
            }
            if let notice = widget.notice { NoticeLine(notice: notice) }
            Text(LaunchSettings.privacy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var countsText: String {
        let sites = "\(widget.pins.sites.count) of \(LaunchPins.maxSites) sites"
        return sites + " · \(widget.pins.shortcuts.count) of \(LaunchPins.maxShortcuts) shortcuts"
    }

    static let privacy = """
    Only http and https sites can be pinned. Icons are fetched only after you pin a site, \
    only from that site's own https address (favicon.ico, apple-touch-icon.png), without cookies, and kept \
    30 days in PlatyNotch's favicons folder; plain http sites get a letter. Add Current Tab asks Safari, \
    Chrome or Arc for the front tab's address only when you click it (macOS asks once per browser). \
    Shortcuts are listed when you open the list and run only when you click one; a run is stopped after \
    60 seconds.
    """
}

private struct PinnedSiteRow: View {
    let widget: LaunchWidget
    let site: PinnedSite

    var body: some View {
        HStack(spacing: 8) {
            SiteIcon(image: widget.icon(for: site), letter: SiteURL.letter(for: site), size: 16)
            Text(verbatim: site.title).lineLimit(1)
            Text(verbatim: site.url.absoluteString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button { widget.move(site, by: -1) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Move \(site.title) up")
            Button { widget.move(site, by: 1) } label: { Image(systemName: "arrow.down") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Move \(site.title) down")
            Button { widget.remove(site) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Unpin \(site.title)")
        }
    }
}

private struct PinnedShortcutRow: View {
    let widget: LaunchWidget
    let shortcut: PinnedShortcut

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill").frame(width: 16).accessibilityHidden(true)
            Text(verbatim: shortcut.name).lineLimit(1)
            Spacer(minLength: 0)
            Button { widget.remove(shortcut) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Unpin \(shortcut.name)")
        }
    }
}
