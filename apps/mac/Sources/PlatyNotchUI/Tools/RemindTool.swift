import PlatyNotchKit
import SwiftUI

/// The Remind tool (Island spec 4): an add field (`QuickAddParser`: "call Priya at 5pm"),
/// then up to eight reminders, overdue first (a red "Overdue"), then today, then upcoming; a
/// circle completes one. Without access: "Allow Reminders", which asks only on that click.
struct RemindTool: View {
    let reminders: RemindersService
    /// Adds the typed line; a message when it could not.
    let onAdd: (String) -> String?
    var onAllow: () -> Void = {}
    var onComplete: (ReminderItem) -> Void = { _ in }
    var fixedNow: Date?
    @State private var draft = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    static let allow = "Allow Reminders"
    static let empty = "Nothing due. Add one above, like \u{201C}call Priya at 5pm\u{201D}."

    /// The section a row sits in.
    static func section(_ item: ReminderItem, overdue: Bool, now: Date, calendar: Calendar) -> String {
        if overdue { return "Overdue" }
        if let due = item.due, calendar.isDate(due, inSameDayAs: now) { return "Today" }
        return "Upcoming"
    }

    /// Everything it prints (tests): section labels before their rows.
    static func texts(_ items: [ReminderItem], access: RemindersService.Access, now: Date,
                      calendar: Calendar) -> [String] {
        switch access {
        case .granted: break
        case .notAsked: return ["Reminders", allow]
        case .denied: return ["Reminders access is off", "Open Settings"]
        case .unavailable: return ["Reminders needs the installed app"]
        }
        let list = RemindersDue.list(items, now: now, calendar: calendar)
        guard !list.isEmpty else { return [empty] }
        var out: [String] = []
        var last: String?
        for row in list {
            let s = section(row.item, overdue: row.overdue, now: now, calendar: calendar)
            if s != last { out.append(s); last = s }
            out.append(row.item.title)
        }
        return out
    }

    var body: some View {
        let now: Date = fixedNow ?? Date()
        VStack(alignment: .leading, spacing: 10) {
            switch reminders.access {
            case .granted:
                ToolField(symbol: "plus", prompt: "Remind me to… (call Priya at 5pm)", text: $draft, focused: $focused,
                          trailing: draft.isEmpty ? nil : "\u{21A9}") {
                    message = onAdd(draft)
                    if message == nil { draft = "" }
                    focused = true
                }
                if let message {
                    Text(verbatim: message).font(DS.font(TypeScale.caption)).foregroundStyle(DS.tertiary)
                        .padding(.horizontal, 4)
                }
                list(now: now)
            case .notAsked:
                access(title: "See what's due and tick it off here.", button: Self.allow, action: onAllow)
            case .denied:
                access(title: "Reminders access is off for PlatyNotch.", button: "Open Settings") {
                    reminders.openSettings()
                }
            case .unavailable:
                ToolEmptyLine(text: "Reminders needs the installed app.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func list(now: Date) -> some View {
        let rows = RemindersDue.list(reminders.items, now: now, calendar: .current)
        if rows.isEmpty {
            ToolEmptyLine(text: Self.empty)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.item.id) { i, row in
                    let s = Self.section(row.item, overdue: row.overdue, now: now, calendar: .current)
                    let previous: String? = i > 0
                        ? Self.section(rows[i - 1].item, overdue: rows[i - 1].overdue, now: now, calendar: .current) : nil
                    if s != previous {
                        Text(verbatim: s.uppercased())
                            .font(DS.font(TypeScale.caption)).tracking(0.6)
                            .foregroundStyle(row.overdue ? DS.color(.error) : DS.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, i == 0 ? 0 : 8)
                            .padding(.bottom, 2)
                    } else {
                        Rectangle().fill(DS.rowHairline).frame(height: 1).padding(.horizontal, 4)
                    }
                    reminderRow(row.item, overdue: row.overdue, now: now)
                }
            }
        }
    }

    private func reminderRow(_ item: ReminderItem, overdue: Bool, now: Date) -> some View {
        HStack(spacing: 10) {
            Button { onComplete(item) } label: {
                Image(systemName: "circle")
                    .font(.system(size: IconSize.header, weight: .regular))
                    .foregroundStyle(DS.tertiary)
                    .frame(width: ToolRow<EmptyView>.wellSize, height: ToolRow<EmptyView>.wellSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Complete")
            .accessibilityLabel("Complete \(item.title)")
            Text(verbatim: item.title)
                .font(DS.font(TypeScale.body))
                .foregroundStyle(DS.primary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(verbatim: RemindersDay.dueText(item, now: now, calendar: .current))
                .font(DS.font(TypeScale.caption))
                .foregroundStyle(overdue ? DS.color(.error) : DS.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private func access(title: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: Space.m) {
            PlatyView(mood: .idle, size: 36)
            Text(verbatim: title).font(DS.font(TypeScale.body)).foregroundStyle(DS.secondary)
            Button(button, action: action).buttonStyle(ToolPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.l)
    }
}
