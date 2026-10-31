import AppKit
import PlatyNotchKit
import SwiftUI

/// The Reminders tile: quick add on top, then overdue and today's reminders with a tick box.
struct RemindersTile: View {
    @Bindable var widget: RemindersWidget
    @Environment(\.inPanelTool) private var inTool

    var body: some View {
        if inTool { tool } else { tile }
    }

    /// Full-panel: how many are due, large, above quick add and the list; access as a calm
    /// empty state with its one action.
    @ViewBuilder private var tool: some View {
        let service = widget.reminders
        switch service.access {
        case .notAsked:
            ToolEmptyState(systemImage: "checkmark.circle", title: "See today's reminders",
                           detail: "Tick them off and add new ones from the notch.",
                           action: ("Allow Reminders Access", { Task { await widget.allow() } }))
        case .denied:
            ToolEmptyState(systemImage: "exclamationmark.circle", title: "Reminders access is off",
                           detail: "Turn it on in System Settings to see today's reminders here.",
                           action: ("Open Settings", { service.openSettings() }))
        case .unavailable:
            ToolEmptyState(systemImage: "checkmark.circle", title: "Reminders needs the installed app",
                           detail: "Reminders show when PlatyNotch runs from its app bundle.")
        case .granted:
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                let n: Int = widget.shown(at: ctx.date).count
                ToolPage(value: n == 0 ? "All clear" : "\(n)", label: n == 0 ? "Nothing due today" : "due today") {
                    content(now: ctx.date)
                }
            }
        }
    }

    @ViewBuilder private var tile: some View {
        let service = widget.reminders
        switch service.access {
        case .notAsked:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                Text("See today's reminders here").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Allow Reminders Access") { Task { await widget.allow() } }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        case .denied:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                Text("Reminders access is off").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Open Settings") { service.openSettings() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
            }
        case .unavailable:
            Label("Reminders needs the installed app.", systemImage: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .granted:
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                content(now: ctx.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        let items = widget.shown(at: now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Add a reminder: call Priya at 5pm", text: $widget.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { widget.addDraft() }
                    .accessibilityLabel("Quick add")
                if !widget.draft.isEmpty {
                    Button("Add") { widget.addDraft() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(6)
            .panelFill(radius: Radius.small)
            if let preview = widget.draft.isEmpty ? nil : widget.preview(at: now) {
                Text(verbatim: preview).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary).padding(.leading, 6)
            } else if let status = widget.status {
                Text(verbatim: status).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary).padding(.leading, 6)
            }
            if items.isEmpty, !inTool {
                Text("Nothing due today").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
            }
            ForEach(items.prefix(RemindersWidget.shownLimit)) { item in
                row(item, now: now)
            }
            if items.count > RemindersWidget.shownLimit {
                Text("+\(items.count - RemindersWidget.shownLimit) more in Reminders")
                    .font(DS.font(TypeScale.caption)).foregroundStyle(.tertiary).padding(.leading, 6)
            }
        }
    }

    private func row(_ item: ReminderItem, now: Date) -> some View {
        let overdue = widget.isOverdue(item, at: now)
        return HStack(spacing: 8) {
            Button { widget.complete(item) } label: {
                Image(systemName: "circle").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Complete \(item.title)")
            Text(verbatim: item.title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Text(verbatim: widget.dueText(item, at: now))
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(overdue ? Theme.tint(.critical) : Color.secondary)
                .accessibilityLabel(overdue ? "Overdue, \(widget.dueText(item, at: now))" : widget.dueText(item, at: now))
        }
        .padding(.horizontal, 6)
    }
}

/// Settings › Widgets › Reminders.
struct RemindersSettings: View {
    let widget: RemindersWidget

    var body: some View {
        let service = widget.reminders
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Reminders access")
                Spacer()
                switch service.access {
                case .granted: Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(DS.secondary).font(DS.font(TypeScale.caption))
                case .notAsked: Button("Allow Reminders Access") { Task { await widget.allow() } }
                case .denied: Button("Open System Settings") { service.openSettings() }
                case .unavailable: Text("Needs the installed app.").foregroundStyle(.secondary).font(DS.font(TypeScale.caption))
                }
            }
            if service.access == .granted {
                Picker("Quick add goes to", selection: Binding(get: { service.defaultListID ?? "" },
                                                               set: { service.defaultListID = $0.isEmpty ? nil : $0 })) {
                    Text("Default list").tag("")
                    ForEach(service.lists) { list in Text(verbatim: list.title).tag(list.id) }
                }
                .frame(maxWidth: 320)
            }
            HStack {
                Text("Events from quick add")
                Spacer()
                if widget.calendar.access == .granted {
                    Text(verbatim: widget.calendar.defaultCalendarTitle ?? "Default calendar").foregroundStyle(.secondary).font(DS.font(TypeScale.caption))
                } else if widget.calendar.access == .notAsked {
                    Button("Allow Calendar Access") { Task { await widget.calendar.requestAccess() } }
                } else {
                    Text("Saved as reminders (Calendar access is off)").foregroundStyle(.secondary).font(DS.font(TypeScale.caption))
                }
            }
            Text("Text with a date and \"meeting\", \"call with\", \"lunch\" or a length (\"for 30 min\") becomes a calendar event; "
                 + "everything else is a reminder. Reminders and Calendar data stay on your Mac.")
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            service.refreshAccess()
            widget.calendar.refreshAccess()
        }
    }
}
