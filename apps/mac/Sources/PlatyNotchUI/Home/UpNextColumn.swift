import PlatyNotchKit
import SwiftUI

/// Home's right column (spec 2.2): "Up next" rows (58 pt time column, title, a quiet note),
/// overdue reminders first in red; "Nothing up next" when empty. Notes and Mail columns
/// share the label and the empty-line shape.
struct UpNextColumn: View {
    let rows: [UpNextRow]
    var onOpen: (() -> Void)?

    static let label = "Up next"
    static let empty = "Nothing up next"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ColumnLabel(text: Self.label)
            if rows.isEmpty {
                Text(verbatim: Self.empty).font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ForEach(rows, id: \.id) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: row.time)
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(row.overdue ? DS.dynamicColor(.error) : Color.secondary)
                            .lineLimit(1)
                            .frame(width: 58, alignment: .leading)
                        Text(verbatim: row.title)
                            .font(.system(size: 13))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let note = row.note {
                            Text(verbatim: note)
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    .padding(.vertical, 3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A column's small caps label.
struct ColumnLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.66)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// The Notes column: today's open tasks, else the quick-notes line.
struct NotesColumn: View {
    let lines: [String]

    static let label = "Notes"
    static let empty = "No open tasks"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ColumnLabel(text: Self.label)
            if lines.isEmpty {
                Text(verbatim: Self.empty).font(.system(size: 12)).foregroundStyle(.tertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).padding(.vertical, 3)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The Mail column: the unread count and the latest subjects.
struct MailColumn: View {
    let unread: Int?
    let subjects: [String]

    static let label = "Mail"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ColumnLabel(text: Self.label)
            if let unread {
                Text(verbatim: unread == 0 ? "No unread mail" : "\(unread) unread")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(Array(subjects.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(.system(size: 13)).lineLimit(1).truncationMode(.tail).padding(.vertical, 3)
                }
            } else {
                Text(verbatim: "Mail is not available").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
