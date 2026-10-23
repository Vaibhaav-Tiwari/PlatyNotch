import PlatyNotchKit
import SwiftUI

/// A short notice ("Claude Code finished", ...) shown while the panel peeks.
struct NoticeToast: View {
    let notice: Notice

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Theme.noticeSymbol(notice.kind))
                .font(.system(size: 18))
                .foregroundStyle(notice.kind == "approval-timeout" ? Theme.color(.attention) : Theme.color(.active))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: notice.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let body = notice.body, !body.isEmpty {
                    Text(verbatim: body)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
