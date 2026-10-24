import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// Quick notes and Obsidian tasks (v0.2 power feature, off by default).
///
/// Quick note: the tile's text field appends `- HH:mm text` to today's daily note in the
/// vault (`<daily folder>/YYYY-MM-DD.md`; the folder must exist, only the note may be
/// made) or, with no vault on, to `notes.noindex/notes.md` (0700/0600).
///
/// Tasks: with a vault chosen in Settings (`NSOpenPanel`, the only place its prompt can
/// appear) the tile lists open tasks from notes edited in the last 30 days (the newest
/// 2000 notes; dot folders skipped). One FSEvents stream on the vault while the widget
/// runs, coalesced, and a rescan only for note or folder changes outside dot folders.
/// Ticking writes back the one checkbox through `TaskFileWriter`: if the note changed
/// since it was read nothing is written, and when the line moved the tile asks first.
///
/// Turned off, or with no vault: no stream, no scan, no file read.
@MainActor @Observable
final class NotesWidget: NotchWidget {
    static let widgetID = "notes"
    /// Tasks shown on the tile.
    static let shownLimit = 6
    /// FSEvents batches within this of each other make one rescan.
    static let rescanDelay: Duration = .seconds(2)

    struct Options: Codable, Equatable {
        static let key = "notes.options"
        var vaultBookmark: Data?
        /// For display only (the bookmark is what is resolved).
        var vaultPath: String?
        var dailyFolder: String = QuickNote.defaultDailyFolder
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
    /// The note changed and the task moved: tick this one? (nothing written yet)
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
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var scanning: Task<Void, Never>?
    @ObservationIgnored private var rescanAgain = false
    @ObservationIgnored private var generation = 0
    /// The grant check after the vault button (tests await it).
    @ObservationIgnored private(set) var accessTask: Task<Void, Never>?
    /// The latest write or append (tests await it).
    @ObservationIgnored private(set) var fileTask: Task<Void, Never>?

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

    /// "Choose Vault…": `url` from `NSOpenPanel`. Lists it once (the macOS prompt shows
    /// here) and keeps it, with the grant stamp, only when that works.
    func chooseVault(_ url: URL) {
        guard isRunning, !asking else { return }
        stopVault()
        updateOptions {
            $0.vaultBookmark = self.services.bookmarks.make(url)
            $0.vaultPath = url.path
            $0.vaultOn = false
        }
        requestAccess(url)
    }

    /// "Turn On Again…" / "Try Again": the saved vault, asked for again.
    func turnOnAgain() {
        guard isRunning, !asking, let url = resolveVault() else { return }
        requestAccess(url)
    }

    /// "Forget": the vault is no longer used (its files are untouched).
    func forgetVault() {
        stopVault()
        stamp.clear()
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

    /// The daily folder as typed is usable (inside the vault, no dot folder).
    var dailyFolderValid: Bool { QuickNote.cleanFolder(options.dailyFolder) != nil }

    private func requestAccess(_ url: URL) {
        asking = true
        let probe = services.probe
        accessTask = Task { @MainActor [weak self] in
            let granted = await probe(url)
            guard let self, !Task.isCancelled, self.isRunning, self.asking else { return }
            self.asking = false
            if granted { self.stamp.note() } else { self.stamp.clear() }
            self.updateOptions {
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
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        vault = rootURL
        watch = services.watch([root]) { [weak self] paths in
            guard VaultAccess.relevant(paths, root: root) else { return }
            self?.scheduleRescan()
        }
        rescan()
    }

    private func stopVault() {
        watch?.stop()
        watch = nil
        rescanTask?.cancel()
        rescanTask = nil
        scanning?.cancel()
        scanning = nil
        rescanAgain = false
        generation += 1
        vault = nil
        index = TaskIndex()
        tasks = []
        capped = false
        noteCount = 0
        pendingAsk = nil
    }

    // MARK: - Scanning

    /// Coalesces FSEvents batches into one rescan after `rescanDelay`.
    private func scheduleRescan() {
        guard rescanTask == nil else { return }
        rescanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.rescanDelay)
            guard !Task.isCancelled, let self else { return }
            self.rescanTask = nil
            self.rescan()
        }
    }

    /// Walks the vault and re-reads changed notes off the main thread; one at a time.
    func rescan() {
        guard let vault else { return }
        if scanning != nil {
            rescanAgain = true
            return
        }
        let mine = generation
        let scan = services.scan
        let read = services.read
        let now = services.clock()
        let calendar = services.calendar
        let current = index
        scanning = Task { @MainActor [weak self] in
            let next = await Task.detached(priority: .utility) { () -> TaskIndex in
                var copy = current
                copy.update(scan(vault, now), calendar: calendar, read: read)
                return copy
            }.value
            guard let self, self.generation == mine else { return }
            self.index = next
            self.tasks = next.openTasks
            self.capped = next.capped
            self.noteCount = next.noteCount
            self.scanning = nil
            if self.rescanAgain {
                self.rescanAgain = false
                self.rescan()
            }
        }
    }

    /// The scan in flight (tests await it).
    var scanTask: Task<Void, Never>? { scanning }

    // MARK: - Ticking

    /// The tick button: written only if the line still reads as it did (R18).
    func toggle(_ task: MarkdownTask) {
        guard vault != nil, !writing.contains(task.id) else { return }
        pendingAsk = nil
        writing.insert(task.id)
        let write = services.toggle
        fileTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { write(task) }.value
            guard let self else { return }
            self.writing.remove(task.id)
            self.handle(result, for: task)
        }
    }

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
        case .failed(let why):
            status = why
        }
        rescan()
    }

    /// "Tick" on the question: the moved task, checked again before writing.
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
        guard vault != nil, let folder = QuickNote.cleanFolder(options.dailyFolder) else { return "PlatyNotch notes" }
        let name = QuickNote.dailyNoteName(for: services.clock(), calendar: services.calendar)
        return folder.isEmpty ? name : folder + "/" + name
    }

    /// Return in the field / "Add".
    func addDraft() {
        guard isRunning, let entry = QuickNote.entry(draft, at: services.clock(), calendar: services.calendar) else { return }
        let target: URL
        let inVault: Bool
        if let vault {
            guard let url = QuickNote.dailyNote(vault: vault, folder: options.dailyFolder, date: services.clock(),
                                                calendar: services.calendar) else {
                status = "The daily notes folder must be a folder inside the vault (Settings)."
                return
            }
            target = url
            inVault = true
        } else {
            target = services.fallbackFolder
            inVault = false
        }
        let label = inVault ? quickNoteTarget : "PlatyNotch notes"
        let sent = draft
        let append = services.append
        let fallback = services.appendFallback
        fileTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                inVault ? append(entry, target, 0o644) : fallback(entry, target)
            }.value
            guard let self else { return }
            switch result {
            case .appended:
                if self.draft == sent { self.draft = "" }
                self.status = "Added to \(label)"
                if inVault { self.rescan() }
            case .failed(let why):
                self.status = why
            }
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
            Button { widget.toggle(task) } label: {
                Image(systemName: "circle").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .disabled(widget.writing.contains(task.id))
            .accessibilityLabel("Complete \(task.title)")
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: task.title).font(.system(size: 12)).lineLimit(1)
                Text(verbatim: NotesWidget.fileName(task.file)).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
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
                if let url = VaultAccess.chooseFolder() { widget.chooseVault(url) }
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
        return "Quick notes are added as \"- HH:mm text\" to today's note in the daily notes folder (the folder must "
            + "exist), or to PlatyNotch's own notes file when no vault is on. Open tasks come from notes edited in the "
            + "last 30 days (the newest 2000; folders starting with a dot are skipped). Ticking a task changes only its "
            + "checkbox, and only if the line still reads the same; nothing else in your vault is changed. A vault in "
            + "Documents or iCloud Drive makes macOS ask once, when you choose it. Nothing leaves your Mac."
    }
}
