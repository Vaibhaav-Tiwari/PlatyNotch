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

    /// The time column's width when any row has a time.
    static let timeColumn: CGFloat = 58

    var body: some View {
        let showsTime: Bool = UpNext.showsTimeColumn(rows)
        VStack(alignment: .leading, spacing: 0) {
            ColumnLabel(text: Self.label)
            if rows.isEmpty {
                Text(verbatim: Self.empty).font(DS.font(TypeScale.secondary)).foregroundStyle(DS.tertiary)
            } else {
                ForEach(rows, id: \.id) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        if showsTime {
                            Text(verbatim: row.time)
                                .font(DS.font(TypeScale.secondary).monospacedDigit())
                                .foregroundStyle(row.overdue ? DS.color(.error) : DS.secondary)
                                .lineLimit(1)
                                .frame(width: Self.timeColumn, alignment: .leading)
                        }
                        Text(verbatim: row.title)
                            .font(DS.font(TypeScale.body))
                            .foregroundStyle(DS.primary)
                            .lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        if let note = row.note {
                            Text(verbatim: note)
                                .font(DS.font(TypeScale.caption))
                                .foregroundStyle(DS.tertiary)
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
            .font(DS.font(TypeScale.caption))
            .tracking(0.66)
            .foregroundStyle(DS.tertiary)
            .padding(.bottom, 3)
            .accessibilityHidden(true)
    }
}

/// The Notes column: today's open tasks, else the quick-notes line.
struct NotesColumn: View {
    let lines: [String]

    static let label = "Notes"
    static let empty = "No open tasks"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ColumnLabel(text: Self.label)
            if lines.isEmpty {
                Text(verbatim: Self.empty).font(DS.font(TypeScale.secondary)).foregroundStyle(DS.tertiary)
            } else {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(DS.font(TypeScale.body)).lineLimit(1).truncationMode(.tail).padding(.vertical, 3)
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
        VStack(alignment: .leading, spacing: 0) {
            ColumnLabel(text: Self.label)
            if let unread {
                Text(verbatim: unread == 0 ? "No unread mail" : "\(unread) unread")
                    .font(DS.font(TypeScale.secondary)).foregroundStyle(DS.secondary)
                ForEach(Array(subjects.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line).font(DS.font(TypeScale.body)).lineLimit(1).truncationMode(.tail).padding(.vertical, 3)
                }
            } else {
                Text(verbatim: "Mail is not available").font(DS.font(TypeScale.secondary)).foregroundStyle(DS.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
