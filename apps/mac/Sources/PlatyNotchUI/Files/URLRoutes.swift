import AppKit
import Observation
import PlatyNotchKit
import SwiftUI

/// What the router acts on (seams: the app passes the running widgets; tests pass fakes).
@MainActor
protocol ShelfAdding: AnyObject {
    /// Adds a file from disk (never owned); false when the shelf is off.
    @discardableResult
    func addFile(_ url: URL) -> Bool
}

extension ShelfWidget: ShelfAdding {}

/// `platynotch://shelf/add`, `timer/start` and `clipboard/open` (R7), and the app's own
/// short notices (the Finder service's "Turn on the Shelf", R8).
///
/// Any web page can open these URLs, so nothing acts from a URL alone: adding files and
/// starting a timer first show a confirm peek ("Add 2 files to the shelf?") with Cancel
/// and a button that does it; letting the peek run out cancels. A route whose widget is
/// off does nothing at all, not even ask. `clipboard/open` only opens the picker (it
/// shows history the user can already see with ⌥⇧V; picking still needs a click or ↩).
/// No work happens between URLs: no timers, no observers.
@MainActor @Observable
final class URLRouter {
    enum Pending: Equatable {
        case addFiles([URL])
        case startTimer(TimeInterval)
    }

    static let confirmID = "routes.confirm"
    static let noticeID = "routes.notice"
    /// How long a confirm peek waits for a click.
    static let confirmTime: TimeInterval = 30
    static let noticeTime: TimeInterval = 4

    private(set) var pending: Pending?
    private(set) var notice: String?

    /// The shelf while it runs, else nil.
    @ObservationIgnored var shelf: @MainActor () -> ShelfAdding? = { nil }
    /// The Time widget while it runs, else nil.
    @ObservationIgnored var timer: @MainActor () -> TimerStarter? = { nil }
    /// Opens the clipboard picker while clipboard history runs; nil while it is off.
    @ObservationIgnored var clipboardPicker: @MainActor () -> (@MainActor () -> Void)? = { nil }
    /// Shows a peek (`PanelSurfaces.peek`); false when nothing could show it.
    @ObservationIgnored var peek: @MainActor (String, Date) -> Bool = { _, _ in false }
    @ObservationIgnored var endPeek: @MainActor (String) -> Void = { _ in }
    @ObservationIgnored var now: () -> Date = Date.init
    /// PlatyNotch's own folder: `shelf/add` never takes a path inside it.
    @ObservationIgnored var home: URL = CorePaths.home()
    @ObservationIgnored var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    @ObservationIgnored private var pendingUntil: Date?

    init() {}

    /// Handles the app's acting routes; false for any other `AppURL`.
    @discardableResult
    func handle(_ route: AppURL) -> Bool {
        switch route {
        case .shelfAdd(let paths):
            guard shelf() != nil,
                  let urls = ShelfAddPolicy.accept(paths, home: home, exists: fileExists), !urls.isEmpty else { return true }
            ask(.addFiles(urls))
        case .timerStart(let seconds):
            guard timer() != nil else { return true }
            ask(.startTimer(seconds))
        case .clipboardOpen:
            clipboardPicker()?()
        default:
            return false
        }
        return true
    }

    private func ask(_ p: Pending) {
        let until = now().addingTimeInterval(Self.confirmTime)
        pending = p
        pendingUntil = until
        if !peek(Self.confirmID, until) { clearPending() }
    }

    /// The confirm peek's button: does what was asked, if its widget still runs and the
    /// peek has not run out.
    func confirm() {
        guard let p = pending, let until = pendingUntil, now() <= until else {
            cancel()
            return
        }
        clearPending()
        endPeek(Self.confirmID)
        switch p {
        case .addFiles(let urls):
            guard let shelf = shelf() else { return }
            // Still there? (the peek waited for a click)
            for url in urls.reversed() where fileExists(url.path) { shelf.addFile(url) }   // the first ends up first
        case .startTimer(let seconds):
            timer()?.startTimer(duration: seconds, label: nil)
        }
    }

    func cancel() {
        let had = pending != nil
        clearPending()
        if had { endPeek(Self.confirmID) }
    }

    private func clearPending() {
        pending = nil
        pendingUntil = nil
    }

    /// A short notice under the notch (`noticeTime`).
    func showNotice(_ text: String) {
        notice = text
        if !peek(Self.noticeID, now().addingTimeInterval(Self.noticeTime)) { notice = nil }
    }

    /// What the confirm peek asks.
    var question: String? {
        switch pending {
        case .addFiles(let urls): AppURLPrompt.addFiles(urls.count)
        case .startTimer(let seconds): AppURLPrompt.startTimer(seconds)
        case nil: nil
        }
    }

    /// The file names, for the confirm peek (at most three, then "and N more").
    var detail: String? {
        guard case .addFiles(let urls) = pending else { return nil }
        let names = urls.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
        return urls.count > 3 ? "\(names) and \(urls.count - 3) more" : names
    }

    /// The peek views (`WidgetRegistry.appPeeks`); nil when there is nothing to show.
    func peekView(id: String) -> AnyView? {
        switch id {
        case Self.confirmID where pending != nil: AnyView(RouteConfirmCard(router: self))
        case Self.noticeID where notice != nil: AnyView(RouteNoticeCard(router: self))
        default: nil
        }
    }
}

struct RouteConfirmCard: View {
    let router: URLRouter

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: router.question ?? "").font(.system(size: 12, weight: .semibold))
                if let detail = router.detail {
                    Text(verbatim: detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Text("Asked by a link").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Cancel") { router.cancel() }
            Button(confirmTitle) { router.confirm() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var confirmTitle: String {
        if case .startTimer = router.pending { return "Start" }
        return "Add"
    }
}

struct RouteNoticeCard: View {
    let router: URLRouter

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full").foregroundStyle(.secondary)
            Text(verbatim: router.notice ?? "").font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
