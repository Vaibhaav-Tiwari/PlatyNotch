import PlatyNotchKit
import SwiftUI

/// An ⓘ beside a setting: its explanation in a popover, so pages show controls first
/// (spec 11). VoiceOver reads the text as the button's hint.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(text)
        .accessibilityLabel("More about this setting")
        .accessibilityHint(text)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(verbatim: text)
                .font(DS.font(TypeScale.body))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

/// A setting's label with its ⓘ: "Open on (i)".
struct SettingLabel: View {
    let title: String
    let info: String?

    init(_ title: String, info: String? = nil) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: title)
            if let info { InfoButton(info) }
        }
    }
}

/// The one accent in Settings: brand teal (never system blue) for switches, checkboxes,
/// prominent buttons and selections, light and dark.
enum SettingsTint {
    static var accent: Color { DS.dynamicColor(.working) }
    static var well: Color { DS.dynamicColor(.working, alpha: 0.14) }
}

/// An SF Symbol in a small tinted well, as in the sidebar and page headers.
struct SymbolWell: View {
    let systemImage: String
    var size: CGFloat = 22
    var filled = false

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(SettingsTint.accent))
            .frame(width: size, height: size)
            .background(filled ? SettingsTint.accent : SettingsTint.well,
                        in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A row that opens a sub-page: title, an optional value, then a chevron.
struct SettingsLinkRow: View {
    let title: String
    var systemImage: String?
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage { SymbolWell(systemImage: systemImage) }
                Text(verbatim: title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                if let value { Text(verbatim: value).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(title)")
    }
}

/// A sub-page's header: a back chevron to its page, then its title.
struct SettingsBackHeader: View {
    let parent: String
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text(verbatim: parent)
            }
            .foregroundStyle(SettingsTint.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to \(parent)")
        .keyboardShortcut("[", modifiers: .command)
    }
}

/// A web link in the one accent (a plain `Link` draws in the system's blue).
struct SettingsLink: View {
    let title: String
    let destination: URL

    init(_ title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            Text(verbatim: title).foregroundStyle(SettingsTint.accent)
        }
        .help(destination.absoluteString)
    }
}
