import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Quick notes and Obsidian tasks (v0.2 power feature, off by default).
///
/// Quick note: the tile's text field appends `- HH:mm text` to today's daily note in the
/// vault (`<daily folder>/YYYY-MM-DD.md`; never made unless "Create today's note if
/// missing" is on, so Obsidian's template is used; no folder is ever made) or, with no
/// vault on, to `notes.noindex/notes.md` (0700/0600).
///
/// Tasks: with a vault chosen in Settings (`NSOpenPanel`, the only place its prompt can
/// appear) the tile lists open tasks from notes edited in the last 30 days (the newest
/// 2000 notes; dot folders skipped). One FSEvents stream on the vault while the widget
/// runs: a note's event re-reads that note only; a folder event, a dropped batch or a
/// slow tick while the tile shows walks the vault. Ticking writes back the one checkbox
/// through `TaskFileWriter`; every write (ticks and appends) goes through one serial
/// `NoteWriter`. Recurring tasks are never written.
///
/// Turned off, or with no vault: no stream, no scan, no file read.
@MainActor @Observable
final class NotesWidget: NotchWidget {
    static let widgetID = "notes"
    /// Tasks shown on the tile.
    static let shownLimit = 6

    struct Options: Codable, Equatable {
        static let key = "notes.options"
        var vaultBookmark: Data?
        /// For display only (the bookmark is what is resolved).
        var vaultPath: String?
        var dailyFolder: String = QuickNote.defaultDailyFolder
        /// Make today's note when it is missing (off: Obsidian makes it from its template).
        var createDailyNote = false
        /// Saved true only after macOS let PlatyNotch list the vault, with the grant stamp.
        var vaultOn = false
        /// Turned off at launch because this build is not the one that was granted.
        var vaultNeedReenable = false
        /// macOS refused the folder at the last try.
        var vaultDenied = false

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vaultBookmark = try c.decodeIfPresent(Data.self, forKey: .vaultBookmark)
            vaultPath = try c.decodeIfPresent(String.self, forKey: .vaultPath)
            dailyFolder = try c.decodeIfPresent(String.self, forKey: .dailyFolder) ?? QuickNote.defaultDailyFolder
            createDailyNote = try c.decodeIfPresent(Bool.self, forKey: .createDailyNote) ?? false
            vaultOn = try c.decodeIfPresent(Bool.self, forKey: .vaultOn) ?? false
            vaultNeedReenable = try c.decodeIfPresent(Bool.self, forKey: .vaultNeedReenable) ?? false
            vaultDenied = try c.decodeIfPresent(Bool.self, forKey: .vaultDenied) ?? false
        }

        static func load(_ d: UserDefaults) -> Options {
            d.data(forKey: key).flatMap { try? JSONDecoder().decode(Options.self, from: $0) } ?? Options()
        }
    }

    let id = NotesWidget.widgetID
    let title = "Notes & Tasks"
    let systemImage = "checklist"
    let defaultEnabled = false
    var category: WidgetCategory { .power }

    private(set) var options: Options
    /// The vault being watched (resolved), while the widget runs with the vault on.
    private(set) var vault: URL?
    /// Open tasks, soonest due first.
    private(set) var tasks: [MarkdownTask] = []
    /// Fewer notes were read than were edited in the window.
    private(set) var capped = false
    private(set) var noteCount = 0
    var draft = ""
    /// One line under the field (where the note went, or why a tick was not written).
    private(set) var status: String?
    /// The note changed and PlatyNotch is not sure of the line: tick this one? (nothing written yet)
    private(set) var pendingAsk: MarkdownTask?
    /// The vault button was pressed and macOS's answer is pending.
    private(set) var asking = false
    /// Tasks being written (their ids): their tick buttons wait.
    private(set) var writing: Set<String> = []

    @ObservationIgnored let services: VaultServices
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let persist: Bool
    @ObservationIgnored private let stamp: GrantStamp
    @ObservationIgnored private(set) var context: WidgetContext?
    @ObservationIgnored private var watch: FolderWatching?
    @ObservationIgnored private var index = TaskIndex()
    /// Events waiting for the rescan delay.
    @ObservationIgnored private(set) var pending = VaultRescan()
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private var queued = VaultRescan()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// The tile is on screen (the periodic walk runs only then).
    @ObservationIgnored private(set) var tileVisible = false
    /// Rescans done (incremental or full), for tests.
    @ObservationIgnored private(set) var rescans = 0
    /// A folder the user chose that macOS refused (Try Again asks for it; never saved).
    @ObservationIgnored private var deniedURL: URL?
    /// The grant check after the vault button (tests await it).
    @ObservationIgnored private(set) var accessTask: Task<Void, Never>?
    /// Writes and appends not finished yet (tests await them).
    @ObservationIgnored private var fileTasks: [Task<Void, Never>] = []

    init(services: VaultServices = .system(), defaults: UserDefaults = .standard, persist: Bool = true) {
        self.services = services
        self.defaults = defaults
        self.persist = persist
        options = Options.load(defaults)
        stamp = GrantStamp(key: "notes.vault.grant", defaults: defaults, identity: services.identity)
    }

    /// No grant, no watch, no files and nothing saved (smoke runs).
    static func inert() -> NotesWidget {
        NotesWidget(services: .none, defaults: UserDefaults(suiteName: "dev.platynotch.inert-notes") ?? .standard,
                    persist: false)
    }

    var isRunning: Bool { context != nil }

    // MARK: - Lifecycle

    func start(context: WidgetContext) {
        guard self.context == nil else { return }
        self.context = context
        guard options.vaultOn else { return }
        switch stamp.launchCheck(wasOn: true) {
        case .resume:
            guard let url = resolveVault() else { return }
            startVault(url)
        case .turnOnAgain, .off:
            updateOptions {
                $0.vaultOn = false
                $0.vaultNeedReenable = true
            }
        }
    }

    func stop() {
        guard context != nil else { return }
        stopVault()
        accessTask?.cancel()
        accessTask = nil
        asking = false
        context = nil
    }

    // MARK: - Vault (settings buttons only)

    /// "Choose Vault…" / "Change…": `url` from `NSOpenPanel`. Lists it once (the macOS
    /// prompt shows here). Only when that works is the bookmark made and the old vault's
    /// bookmark and stamp replaced; a refused folder leaves a working vault as it was.
    func chooseVault(_ url: URL) {
        guard isRunning, !asking else { return }
        requestAccess(url, choosing: true)
    }

    /// "Turn On Again…" / "Try Again": the saved (or just refused) vault, asked for again.
    func turnOnAgain() {
        guard isRunning, !asking else { return }
        if let url = deniedURL {
            requestAccess(url, choosing: true)
        } else if let url = resolveVault() {
            requestAccess(url, choosing: false)
        }
    }

    /// "Forget": the vault is no longer used (its files are untouched).
    func forgetVault() {
        stopVault()
        stamp.clear()
        deniedURL = nil
        updateOptions {
            $0.vaultBookmark = nil
            $0.vaultPath = nil
            $0.vaultOn = false
            $0.vaultNeedReenable = false
            $0.vaultDenied = false
        }
    }

    func setDailyFolder(_ folder: String) {
        updateOptions { $0.dailyFolder = folder }
    }

    func setCreateDailyNote(_ on: Bool) {
        updateOptions { $0.createDailyNote = on }
    }

    /// The daily folder as typed is usable (inside the vault, no dot folder).
    var dailyFolderValid: Bool { QuickNote.cleanFolder(options.dailyFolder) != nil }

    private func requestAccess(_ url: URL, choosing: Bool) {
        asking = true
        let probe = services.probe
        accessTask = Task { @MainActor [weak self] in
            var granted = await probe(url)
            guard let self, !Task.isCancelled, self.isRunning, self.asking else { return }
            self.asking = false
            // The bookmark only after the grant; none means no vault.
            var bookmark = self.options.vaultBookmark
            if granted, choosing {
                bookmark = self.services.bookmarks.make(url)
                if bookmark == nil { granted = false }
            }
            if !granted, choosing, self.vault != nil {
                // "Change…" refused: the vault in use stays, with its bookmark and stamp.
                self.status = "macOS did not allow PlatyNotch to see \(url.lastPathComponent), so the vault is unchanged."
                return
            }
            if granted { self.stopVault() }
            if granted { self.stamp.note() } else { self.stamp.clear() }
            self.deniedURL = granted ? nil : url
            self.updateOptions {
                if choosing {
                    $0.vaultBookmark = granted ? bookmark : nil
                    $0.vaultPath = url.path
                }
                $0.vaultOn = granted
                $0.vaultDenied = !granted
                $0.vaultNeedReenable = false
            }
            if granted { self.startVault(url) }
        }
    }

    private func resolveVault() -> URL? {
        guard let data = options.vaultBookmark, let r = services.bookmarks.resolve(data) else {
            if options.vaultBookmark != nil { status = "The vault folder could not be found. Choose it again in Settings." }
            return nil
        }
        if r.isStale, let fresh = services.bookmarks.make(r.url) {
            updateOptions {
                $0.vaultBookmark = fresh
                $0.vaultPath = r.url.path
            }
        }
        return r.url
    }

    private func startVault(_ url: URL) {
        guard isRunning, watch == nil else { return }
        let root = services.resolve(url.path)
        vault = URL(fileURLWithPath: root, isDirectory: true)
        watch = services.watch(root) { [weak self] events in
            self?.received(events, root: root)
        }
        rescan(VaultRescan(full: true))
        // The tile was already showing (a vault turned on from Settings): its walk starts now.
        if tileVisible { tileShown() }
    }

    /// The periodic walk is set up (tests).
    var periodicWalkRunning: Bool { periodicTask != nil }

    private func stopVault() {
        watch?.stop()
        watch = nil
        rescanTask?.cancel()
        rescanTask = nil
        scanning?.cancel()
        scanning = nil
        periodicTask?.cancel()
        periodicTask = nil
        pending = VaultRescan()
        queued = VaultRescan()
        generation += 1
        vault = nil
        index = TaskIndex()
        tasks = []
        capped = false
        noteCount = 0
        pendingAsk = nil
    }

    // MARK: - Scanning

    /// An FSEvents batch: nothing for dot folders and other files; else one rescan after
    /// `rescanDelay` for every batch that arrives meanwhile.
    func received(_ events: [VaultEvent], root: String) {
        guard watch != nil else { return }
        let plan = VaultRescan.plan(events, root: root)
        guard !plan.isEmpty else { return }
        pending.merge(plan)
        guard rescanTask == nil else { return }
        let delay = services.rescanDelay
        rescanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.rescanTask = nil
            let work = self.pending
            self.pending = VaultRescan()
            self.rescan(work)
        }
    }

    /// A rescan is waiting for its delay (tests).
    var rescanScheduled: Bool { rescanTask != nil }

    /// A full walk (`work.full`) or a fresh look at `work.paths`, off the main thread; one
    /// at a time (work that arrives meanwhile runs next).
    func rescan(_ work: VaultRescan) {
        guard let vault, !work.isEmpty else { return }
        if scanning != nil {
            queued.merge(work)
            return
        }
        let mine = generation
        let services = self.services
        let now = services.clock()
        let current = index
        rescans += 1
        scanning = Task { @MainActor [weak self] in
            let next = await Task.detached(priority: .utility) { () -> TaskIndex in
                var copy = current
                if work.full {
                    copy.update(services.scan(vault, now), calendar: services.calendar, read: services.read)
                } else {
                    copy.refresh(Array(work.paths), calendar: services.calendar,
                                 stat: { services.stat($0, vault.path, now) }, read: services.read)
                }
                return copy
            }.value
            guard let self, self.generation == mine else { return }
            self.index = next
            self.tasks = next.openTasks
            self.capped = next.capped
            self.noteCount = next.noteCount
            self.scanning = nil
            if !self.queued.isEmpty {
                let more = self.queued
                self.queued = VaultRescan()
                self.rescan(more)
            }
        }
    }

    /// The scan in flight (tests await it).
    var scanTask: Task<Void, Never>? { scanning }

    /// The tile appeared: a full walk every `periodicRescan` while it shows (new notes the
    /// events missed, the 30-day window moving on). Nothing while it is hidden.
    func tileShown() {
        tileVisible = true
        guard vault != nil, periodicTask == nil else { return }
        let every = services.periodicRescan
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled, let self else { return }
                self.rescan(VaultRescan(full: true))
            }
        }
    }

    func tileHidden() {
        tileVisible = false
        periodicTask?.cancel()
        periodicTask = nil
    }

    // MARK: - Ticking

    /// The tick button: written only if the line still reads as it did (R18). One write at
    /// a time (`NoteWriter`).
    func toggle(_ task: MarkdownTask) {
        guard vault != nil, !writing.contains(task.id) else { return }
        if task.isRecurring {
            status = Self.recurringText
            return
        }
        pendingAsk = nil
        writing.insert(task.id)
        let write = services.toggle
        let writer = services.writer
        track(Task { @MainActor [weak self] in
            let result = await writer.run { write(task) }
            guard let self else { return }
            self.writing.remove(task.id)
            self.handle(result, for: task)
        })
    }

    static let recurringText = "Recurring tasks are ticked in Obsidian, which makes the next one."

    private func handle(_ result: TaskWriteResult, for task: MarkdownTask) {
        switch result {
        case .toggled:
            status = nil
        case .moved(let found):
            pendingAsk = found
            status = "“\(Self.fileName(found.file))” changed since it was read. Tick “\(found.title)” on line \(found.line)?"
        case .changed:
            status = "“\(Self.fileName(task.file))” changed since it was read, so nothing was ticked. The list is up to date again."
        case .readOnly:
            status = "“\(Self.fileName(task.file))” is read-only, so nothing was ticked."
        case .recurring:
            status = Self.recurringText
        case .failed(let why):
            status = why
        }
        rescan(VaultRescan(paths: [task.file]))
    }

    /// "Tick It" on the question: the task, checked again before writing.
    func confirmAsk() {
        guard let t = pendingAsk else { return }
        toggle(t)
    }

    func cancelAsk() {
        pendingAsk = nil
        status = nil
    }

    // MARK: - Quick note

    /// Where a quick note goes now, for the field's placeholder.
    var quickNoteTarget: String {
        guard vault != nil,
              let path = QuickNote.dailyNotePath(folder: options.dailyFolder, date: services.clock(),
                                                 calendar: services.calendar) else { return "PlatyNotch notes" }
        return path
    }

    /// Return in the field / "Add". One write at a time (`NoteWriter`).
    func addDraft() {
        guard isRunning, let entry = QuickNote.entry(draft, at: services.clock(), calendar: services.calendar) else { return }
        let sent = draft
        let writer = services.writer
        if let vault {
            guard let rel = QuickNote.dailyNotePath(folder: options.dailyFolder, date: services.clock(),
                                                    calendar: services.calendar) else {
                status = "The daily notes folder must be a folder inside the vault (Settings)."
                return
            }
            let append = services.append
            let mode: mode_t? = options.createDailyNote ? 0o644 : nil
            track(Task { @MainActor [weak self] in
                let result = await writer.run { append(entry, vault, rel, mode) }
                self?.appended(result, sent: sent, label: rel, refresh: vault.appendingPathComponent(rel).path)
            })
        } else {
            let fallback = services.appendFallback
            let folder = services.fallbackFolder
            track(Task { @MainActor [weak self] in
                let result = await writer.run { fallback(entry, folder) }
                self?.appended(result, sent: sent, label: "PlatyNotch notes", refresh: nil)
            })
        }
    }

    private func appended(_ result: QuickNote.AppendResult, sent: String, label: String, refresh: String?) {
        switch result {
        case .appended:
            if draft == sent { draft = "" }
            status = "Added to \(label)"
            if let refresh { rescan(VaultRescan(paths: [refresh])) }
        case .noNote:
            status = QuickNote.noDailyNote
        case .failed(let why):
            status = why
        }
    }

    private func track(_ task: Task<Void, Never>) {
        fileTasks.append(task)
    }

    /// Waits for every write and append started so far (tests).
    func settleWrites() async {
        while let t = fileTasks.first {
            await t.value
            fileTasks.removeFirst()
        }
    }

    // MARK: - Helpers

    func updateOptions(_ change: (inout Options) -> Void) {
        var next = options
        change(&next)
        guard next != options else { return }
        options = next
        if persist, let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Options.key) }
    }

    static func fileName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// "Today", "Tomorrow", "Overdue" or a short date.
    func dueText(_ task: MarkdownTask) -> String? {
        guard let due = task.due else { return nil }
        let cal = services.calendar
        let today = cal.startOfDay(for: services.clock())
        if due < today { return "Overdue" }
        if cal.isDate(due, inSameDayAs: today) { return "Today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today), cal.isDate(due, inSameDayAs: tomorrow) { return "Tomorrow" }
        return due.formatted(.dateTime.month(.abbreviated).day())
    }

    // MARK: - Views

    func tileView() -> AnyView { AnyView(NotesTile(widget: self)) }

    func settingsView() -> AnyView? { AnyView(NotesSettings(widget: self)) }
}

/// The tile: quick note on top, then open tasks with a tick box.
struct NotesTile: View {
    @Bindable var widget: NotesWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Quick note to \(widget.quickNoteTarget)", text: $widget.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { widget.addDraft() }
                    .accessibilityLabel("Quick note")
                if !widget.draft.isEmpty {
                    Button("Add") { widget.addDraft() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let status = widget.status {
                Text(verbatim: status).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 6)
            }
            if widget.pendingAsk != nil {
                HStack(spacing: 8) {
                    Button("Tick It") { widget.confirmAsk() }
                    Button("Cancel") { widget.cancelAsk() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .padding(.leading, 6)
            }
            tasks
        }
        .onAppear { widget.tileShown() }
        .onDisappear { widget.tileHidden() }
    }

    @ViewBuilder private var tasks: some View {
        if widget.vault == nil {
            Text(widget.options.vaultNeedReenable
                 ? "Turn the vault on again in Settings › Widgets › Notes & Tasks to see its tasks."
                 : "Choose a vault in Settings › Widgets › Notes & Tasks to see its open tasks.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 6)
        } else if widget.tasks.isEmpty {
            Text("No open tasks in notes edited in the last 30 days")
                .font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 6)
        } else {
            ForEach(widget.tasks.prefix(NotesWidget.shownLimit)) { task in
                row(task)
            }
            if widget.tasks.count > NotesWidget.shownLimit {
                Text("+\(widget.tasks.count - NotesWidget.shownLimit) more")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 6)
            }
        }
        if widget.vault != nil, widget.capped {
            Text("Showing tasks from the newest \(widget.noteCount) notes")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 6)
        }
    }

    private func row(_ task: MarkdownTask) -> some View {
        let due = widget.dueText(task)
        return HStack(spacing: 8) {
            if task.isRecurring {
                // Never written here: the Tasks plugin makes the next one.
                Image(systemName: "repeat").font(.system(size: 11)).foregroundStyle(.tertiary)
                    .help("Tick it in Obsidian")
                    .accessibilityHidden(true)
            } else {
                Button { widget.toggle(task) } label: {
                    Image(systemName: "circle").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .disabled(widget.writing.contains(task.id))
                .accessibilityLabel("Complete \(task.title)")
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: task.title).font(.system(size: 12)).lineLimit(1)
                Text(verbatim: NotesWidget.fileName(task.file) + (task.isRecurring ? " · Tick it in Obsidian" : ""))
                    .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let due {
                Text(verbatim: due)
                    .font(.system(size: 10))
                    .foregroundStyle(due == "Overdue" ? Theme.tint(.critical) : Color.secondary)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Settings › Widgets › Notes & Tasks: the vault button is the only place its prompt shows.
struct NotesSettings: View {
    @Bindable var widget: NotesWidget

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(vaultText, systemImage: "folder").lineLimit(1).truncationMode(.middle)
                Spacer()
                buttons
            }
            HStack {
                Text("Daily notes folder")
                TextField(QuickNote.defaultDailyFolder, text: Binding(get: { widget.options.dailyFolder },
                                                                     set: { widget.setDailyFolder($0) }))
                    .frame(maxWidth: 200)
            }
            Toggle("Create today's note if missing", isOn: Binding(get: { widget.options.createDailyNote },
                                                                   set: { widget.setCreateDailyNote($0) }))
            if !widget.dailyFolderValid {
                Text("Use a folder inside the vault, such as Daily or Journal/Daily.")
                    .font(.caption).foregroundStyle(Theme.tint(.warning))
            }
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vaultText: String {
        guard let p = widget.options.vaultPath else { return "No vault" }
        return (p as NSString).abbreviatingWithTildeInPath
    }

    @ViewBuilder private var buttons: some View {
        if widget.asking {
            ProgressView().controlSize(.small)
        } else {
            if widget.options.vaultPath != nil, !widget.options.vaultOn {
                if widget.options.vaultDenied {
                    Button("Open System Settings") { Permissions.open(.filesAndFolders) }
                }
                Button(widget.options.vaultDenied ? "Try Again" : "Turn On Again…") { widget.turnOnAgain() }
            }
            Button(widget.options.vaultPath == nil ? "Choose Vault…" : "Change…") {
                VaultAccess.chooseFolder { [widget] url in widget.chooseVault(url) }
            }
            if widget.options.vaultPath != nil {
                Button("Forget") { widget.forgetVault() }
            }
        }
    }

    private var status: String {
        if widget.asking { return "Waiting for macOS to allow the folder." }
        if widget.options.vaultNeedReenable {
            return "Turn on again (PlatyNotch was updated or reinstalled): macOS may need to ask once more."
        }
        if widget.options.vaultDenied {
            return "macOS did not allow PlatyNotch to see that folder (System Settings › Privacy & Security › "
                + "Files and Folders). Quick notes go to PlatyNotch's own notes file meanwhile."
        }
        return "Quick notes are added as \"- HH:mm text\" to today's note in the daily notes folder (open it in "
            + "Obsidian first so its template is used, or turn on creating it; the folder must exist), or to PlatyNotch's own notes file when no vault is on. Open tasks come from notes edited in the "
            + "last 30 days (the newest 2000; folders starting with a dot are skipped). Ticking a task changes only its "
            + "checkbox, and only if the line still reads the same; recurring tasks are ticked in Obsidian. Nothing "
            + "else in your vault is changed. A vault in "
            + "Documents or iCloud Drive makes macOS ask once, when you choose it. Nothing leaves your Mac."
    }
}
