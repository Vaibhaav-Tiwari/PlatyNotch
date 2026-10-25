import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Apple Mail (v0.2 power feature, R21): the inbox's unread count and the sender and
/// subject of the newest unread messages; clicking one opens it in Mail.
///
/// Privacy: off by default. Mail is never launched: nothing is sent to it, no script runs
/// and no link is opened unless `NSWorkspace` says Mail is running (and the script itself
/// returns at once if Mail has quit meanwhile). The Automation prompt appears only from the
/// tile's Allow button: every read first checks the status without asking and runs the
/// script only when it is already granted. The script addresses the Mail process by the
/// pid `NSWorkspace` reported, so a Mail that quit meanwhile is never relaunched. What is read stays in memory while the widget
/// runs and Mail is open; it is dropped when Mail quits or the widget stops, and never
/// saved, logged or sent. Only sender, subject, date and Message-ID (for the link) are read.
///
/// Refresh: one `/usr/bin/osascript` run (`MailScript`, killed after 5 s) every 5 minutes
/// while the widget is on and Mail is open, plus when the tile appears (at most every
/// 30 s). With Mail closed the tile says "Mail is not open" and nothing runs.
@MainActor @Observable
final class MailWidget: NotchWidget {
    static let widgetID = "mail"

    enum Phase: Equatable {
        /// The widget is not running.
        case off
        case notOpen
        case loading
        /// Automation was never asked: the tile's Allow button asks.
        case needsAllow
        case denied(GrantHistory)
        case inbox(MailInbox)
        case failed(String)
    }

    let id = MailWidget.widgetID
    let title = "Mail"
    let systemImage = "envelope"
    let defaultEnabled = false
    let category = WidgetCategory.power

    private(set) var phase: Phase = .off
    /// The inbox shown (in memory only).
    var inbox: MailInbox? {
        if case .inbox(let i) = phase { return i }
        return nil
    }

    @ObservationIgnored private let system: MailSystem
    @ObservationIgnored private let grants: AutomationGrants
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private(set) var running = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var readSerial = 0
    @ObservationIgnored private var lastRead: Date?
    /// Bumped on every stop and Mail quit: a read that finishes after it is dropped.
    @ObservationIgnored private var generation = 0

    init(system: MailSystem = .system,
         grants: AutomationGrants = AutomationGrants(defaults: .standard, identity: { CodeIdentity.current }),
         clock: @escaping () -> Date = Date.init) {
        self.system = system
        self.grants = grants
        self.clock = clock
    }

    /// Never looks at Mail, runs nothing, saves nothing (smoke runs).
    static func inert() -> MailWidget {
        MailWidget(system: .inert, grants: AutomationGrants(defaults: nil, identity: { "inert" }))
    }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard !running else { return }
        running = true
        observers = system.watchMail { [weak self] in self?.mailChanged() }
        mailChanged()
    }

    func stop() {
        running = false
        system.unwatch(observers)
        observers = []
        forget()
        phase = .off
    }

    // MARK: - Events

    /// Mail launched or quit (and at start).
    private func mailChanged() {
        guard running else { return }
        if system.mailPID() != nil {
            guard loop == nil else { return }
            let sleep = system.sleep
            loop = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.read()
                    await sleep(MailRefresh.interval)
                }
            }
        } else {
            forget()
            phase = .notOpen
        }
    }

    /// Stops the loop and any running script, and drops what was read.
    private func forget() {
        generation += 1
        loop?.cancel()
        loop = nil
        inFlight?.cancel()   // kills osascript
        inFlight = nil
        lastRead = nil
    }

    /// The tile appeared: read again unless it was read in the last 30 s.
    func tileAppeared() {
        guard running else { return }
        guard system.mailPID() != nil else { mailChanged(); return }
        guard MailRefresh.dueOnOpen(last: lastRead, now: clock()) else { return }
        Task { await read() }
    }

    /// The tile's Allow button: the only place the Automation prompt can appear.
    func allow() async {
        guard running else { return }
        guard system.mailPID() != nil else { mailChanged(); return }
        let state = await system.automation(true)
        if state == .granted { grants.noteAccepted(MailSystem.mailID) }
        // A read that began before the answer saw "not asked": let it finish, then read
        // again with the new answer.
        if let inFlight { await inFlight.value }
        lastRead = nil
        await read()
    }

    /// Opens a message in Mail (its `message:` link, else Mail's window). Only while Mail
    /// runs: a link would launch it otherwise.
    func open(_ message: MailMessage) {
        guard running else { return }
        guard system.mailPID() != nil else { mailChanged(); return }
        if let url = message.openURL { system.open(url) } else { system.activateMail() }
    }

    func openAutomationSettings() { Permissions.open(.automation) }

    // MARK: - Reading

    /// One read: Mail running → status without asking → the script only when granted.
    func read() async {
        if let inFlight { await inFlight.value; return }
        readSerial += 1
        let serial = readSerial
        // The task clears itself, so whoever resumes first after it sees no stale read.
        let task = Task { [weak self] () -> Void in
            await self?.readOnce()
            if let self, self.readSerial == serial { self.inFlight = nil }
        }
        inFlight = task
        await task.value
    }

    private func readOnce() async {
        let gen = generation
        guard running, system.mailPID() != nil else { if running { phase = .notOpen }; return }
        lastRead = clock()
        if inbox == nil { phase = .loading }
        let status = await system.automation(false)
        guard gen == generation, running else { return }
        switch status {
        case .granted: break
        case .notAsked: phase = .needsAllow; return
        case .denied: phase = .denied(grants.history(MailSystem.mailID)); return
        case .unavailable:
            // procNotFound: Mail quit between the check and the status.
            phase = system.mailPID() != nil ? .failed("Mail did not answer.") : .notOpen
            return
        }
        // Mail may have quit while the status was read: never run the script then.
        guard let pid = system.mailPID() else { phase = .notOpen; return }
        let result = await system.osascript(MailScript.arguments(pid: pid))
        guard gen == generation, running, !Task.isCancelled else { return }
        switch MailScriptOutcome.classify(status: result.status, stdout: result.stdout, stderr: result.stderr,
                                          timedOut: result.timedOut, truncated: result.truncated) {
        case .inbox(let i):
            grants.noteAccepted(MailSystem.mailID)
            phase = .inbox(i)
        case .notRunning: phase = .notOpen
        case .denied: phase = .denied(grants.history(MailSystem.mailID))
        case .timedOut: if inbox == nil { phase = .failed("Mail took too long to answer. Trying again later.") }
        case .failed(let why): if inbox == nil { phase = .failed(why) }
        }
    }

    var kind: WidgetKind { [.glance, .tool] }

    /// Unread messages in the inbox shown (0 until Mail is read).
    var unreadCount: Int { inbox?.unread ?? 0 }

    var hasContent: Bool { unreadCount > 0 }

    /// "Mail 4".
    func glanceView() -> AnyView? { AnyView(MailGlance(widget: self)) }

    func tileView() -> AnyView { AnyView(MailTileView(widget: self)) }

    func settingsView() -> AnyView? { AnyView(MailSettingsView()) }
}

/// The Today tile.
struct MailTileView: View {
    let widget: MailWidget
    @Environment(\.inLibraryTool) private var inTool

    var body: some View {
        Group {
            if inTool {
                tool
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    content
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsCard()
            }
        }
        .onAppear { widget.tileAppeared() }
    }

    /// Full-panel: the newest unread as rows, or what Mail needs, centred.
    @ViewBuilder private var tool: some View {
        switch widget.phase {
        case .off, .loading:
            ToolEmptyState(systemImage: "envelope", title: "Reading Mail…", detail: "Unread senders and subjects show here.")
        case .notOpen:
            ToolEmptyState(systemImage: "envelope", title: "Mail is not open",
                           detail: "Open Mail to see your unread messages here. PlatyNotch never opens it for you.")
        case .needsAllow:
            ToolEmptyState(systemImage: "envelope.badge", title: "Allow reading Mail",
                           detail: "PlatyNotch reads only the unread count, senders and subjects, and keeps nothing.",
                           action: ("Allow", { Task { await widget.allow() } }))
        case .denied(let history):
            ToolEmptyState(systemImage: "lock", title: "Mail access is off",
                           detail: PermissionAdvice.automationDenied(app: "Mail", history: history),
                           action: ("Open Settings", { widget.openAutomationSettings() }))
        case .failed(let why):
            ToolEmptyState(systemImage: "exclamationmark.triangle", title: "Mail did not answer", detail: why)
        case .inbox(let inbox):
            if inbox.latest.isEmpty {
                ToolEmptyState(systemImage: "envelope.open", title: "No unread mail", detail: "You are all caught up.")
            } else {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(verbatim: inbox.unread == 1 ? "1 unread · click to open in Mail"
                                                      : "\(inbox.unread) unread · click to open in Mail")
                        .font(DS.font(TypeScale.caption))
                        .foregroundStyle(.secondary)
                    ForEach(inbox.latest) { m in
                        toolRow(m)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }

    private func toolRow(_ m: MailMessage) -> some View {
        Button { widget.open(m) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: m.sender.isEmpty ? "Unknown sender" : m.sender)
                    .font(DS.font(TypeStyle(size: TypeScale.body.size, weight: .semibold))).lineLimit(1)
                Text(verbatim: m.subject.isEmpty ? "No subject" : m.subject)
                    .font(DS.font(TypeScale.body)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(m.sender), \(m.subject)"))
        .accessibilityHint("Opens it in Mail")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "envelope").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Mail").font(.system(size: 12, weight: .semibold))
            if let inbox = widget.inbox {
                Text(verbatim: inbox.unread == 1 ? "1 unread" : "\(inbox.unread) unread")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch widget.phase {
        case .off, .loading:
            note("Reading Mail…")
        case .notOpen:
            note("Mail is not open")
        case .needsAllow:
            HStack(spacing: 8) {
                note("Allow PlatyNotch to read the unread count, senders and subjects from Mail.")
                Spacer(minLength: 0)
                Button("Allow") { Task { await widget.allow() } }.controlSize(.small)
            }
        case .denied(let history):
            HStack(spacing: 8) {
                note(PermissionAdvice.automationDenied(app: "Mail", history: history))
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Open Settings") { widget.openAutomationSettings() }.controlSize(.small)
            }
        case .failed(let why):
            note(why)
        case .inbox(let inbox):
            if inbox.latest.isEmpty {
                note("No unread mail")
            } else {
                ForEach(inbox.latest) { m in row(m) }
            }
        }
    }

    private func row(_ m: MailMessage) -> some View {
        Button { widget.open(m) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: m.sender.isEmpty ? "Unknown sender" : m.sender)
                    .font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(verbatim: m.subject.isEmpty ? "No subject" : m.subject)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(m.sender), \(m.subject)"))
        .accessibilityHint("Opens it in Mail")
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Settings › Widgets › Mail.
struct MailSettingsView: View {
    var body: some View {
        Text("""
        Shows Mail's unread count and the sender and subject of the newest unread messages, \
        read every 5 minutes while Mail is open. PlatyNotch never opens Mail itself, asks for \
        Automation only from the tile's Allow button, and keeps nothing: what it reads stays \
        in memory until Mail quits or you turn this off.
        """)
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The unread-mail glance.
private struct MailGlance: View {
    let widget: MailWidget

    var body: some View {
        GlanceChip(systemImage: widget.systemImage, value: "\(widget.unreadCount)", label: "Mail")
    }
}
