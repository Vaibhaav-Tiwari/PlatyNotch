import PlatyNotchKit
import SwiftUI

/// Settings › Notifications' state: the per-kind policy (`NotificationPolicy`), saved on
/// every change; the app hands it to the panels at once.
@MainActor @Observable
final class NotificationsModel {
    /// What one cell of the table shows: a switch, or a fixed answer ("Always", "Never").
    enum Cell: Equatable {
        case toggle(Bool)
        case locked(String)
    }

    private(set) var policy: NotificationPolicy
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        policy = NotificationPolicy.load(from: defaults)
    }

    static let fields: [NotificationField] = [.showInPill, .canOpen, .quietDuringFocus]

    static func cell(_ kind: NotificationKind, _ field: NotificationField, policy: NotificationPolicy) -> Cell {
        let on: Bool = policy[kind][field]
        guard NotificationPolicy.isLocked(kind, field) else { return .toggle(on) }
        return .locked(on ? "Always" : "Never")
    }

    func cell(_ kind: NotificationKind, _ field: NotificationField) -> Cell { Self.cell(kind, field, policy: policy) }

    /// Changes one cell; a locked cell keeps its value (the policy refuses it too).
    func set(_ kind: NotificationKind, _ field: NotificationField, _ on: Bool) {
        guard !NotificationPolicy.isLocked(kind, field) else { return }
        var rule = policy[kind]
        rule[field] = on
        policy[kind] = rule
        policy.save(to: defaults)
    }

    static func title(_ kind: NotificationKind) -> String {
        switch kind {
        case .approval: "Approvals"
        case .agentNeedsYou: "Agent needs you or stopped"
        case .agentFinished: "Agent finished"
        case .ringing: "Alarms and timers"
        case .meetingStarting: "Meeting starting"
        case .reminder: "Reminders you asked for"
        case .other: "Everything else"
        case .pluginUndeclared: "Plug-ins without a kind"
        }
    }

    static func systemImage(_ kind: NotificationKind) -> String {
        switch kind {
        case .approval: "checkmark.shield"
        case .agentNeedsYou: "hand.raised"
        case .agentFinished: "checkmark.circle"
        case .ringing: "alarm"
        case .meetingStarting: "calendar"
        case .reminder: "drop"
        case .other: "tray"
        case .pluginUndeclared: "puzzlepiece.extension"
        }
    }

    static func detail(_ kind: NotificationKind) -> String {
        switch kind {
        case .approval: "An agent asks before running a tool. Approvals always show and open the notch, even during Focus; nothing here can silence them."
        case .agentNeedsYou: "An agent is waiting for your input, or stopped with an error."
        case .agentFinished: "An agent finished its work: a short notice, then a summary in Now."
        case .ringing: "An alarm or a timer reaching zero. With Can open off it still rings; stop it from the menu bar or the pill."
        case .meetingStarting: "A meeting in your calendar is about to start."
        case .reminder: "Water, stand and eye-rest nudges, and AirPods connecting."
        case .other: "Downloads, charging and anything not listed above."
        case .pluginUndeclared: "Peeks from plug-ins that do not say what kind they are."
        }
    }

    static func column(_ field: NotificationField) -> String {
        switch field {
        case .showInPill: "Show in pill"
        case .canOpen: "Can open"
        case .quietDuringFocus: "Quiet in Focus"
        }
    }
}

/// Settings › Notifications (spec 6.3): one row per kind, three switches each. Approvals'
/// cells are fixed. "Quiet in Focus" follows PlatyNotch's focus session.
struct NotificationsSection: View {
    @State private var model: NotificationsModel
    /// Settings › Notifications › Sound (Phase 7: the optional "plip" and "Choose sound
    /// file…"); nothing until then.
    let sound: AnyView?

    init(defaults: UserDefaults = .standard, sound: AnyView? = nil) {
        _model = State(initialValue: NotificationsModel(defaults: defaults))
        self.sound = sound
    }

    static let columnWidth: CGFloat = 80

    var body: some View {
        SettingsPage("Notifications", subtitle: "What may show in the pill and open the notch by itself.") {
            VStack(spacing: 0) {
                header
                ForEach(Array(NotificationKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { Divider().padding(.leading, 46) }
                    row(kind)
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            if let sound {
                Text("Sound").font(.system(size: 13, weight: .semibold)).padding(.top, 8)
                sound
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(NotificationsModel.fields, id: \.self) { field in
                Text(verbatim: NotificationsModel.column(field))
                    .font(DS.font(TypeScale.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: Self.columnWidth)
            }
        }
        .padding(.vertical, 6)
        .accessibilityHidden(true)
    }

    private func row(_ kind: NotificationKind) -> some View {
        HStack(spacing: 10) {
            SymbolWell(systemImage: NotificationsModel.systemImage(kind), size: 26)
            SettingLabel(NotificationsModel.title(kind), info: NotificationsModel.detail(kind))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ForEach(NotificationsModel.fields, id: \.self) { field in
                cell(kind, field).frame(width: Self.columnWidth)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NotificationsModel.title(kind))
    }

    @ViewBuilder private func cell(_ kind: NotificationKind, _ field: NotificationField) -> some View {
        let label: String = "\(NotificationsModel.title(kind)): \(NotificationsModel.column(field))"
        switch model.cell(kind, field) {
        case .toggle(let on):
            Toggle(isOn: Binding(get: { on }, set: { model.set(kind, field, $0) })) { Text(verbatim: label) }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(label)
        case .locked(let word):
            HStack(spacing: 3) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.tertiary)
                Text(verbatim: word).font(DS.font(TypeScale.caption)).foregroundStyle(.secondary)
            }
            .help("Approvals cannot be silenced")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label): \(word), cannot be changed")
        }
    }
}
