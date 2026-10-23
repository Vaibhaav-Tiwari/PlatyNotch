import Observation
import PlatyNotchKit
import SwiftUI

/// The Memory tab's models, one set shared by every display's panel.
@MainActor
public final class MemoryServices {
    public let search: MemorySearchModel
    /// Nil when capture is not running in this process (tests, previews).
    public let capture: CaptureService?
    /// Opens Settings at the memory section (wired by the Settings task).
    public var onOpenSettings: () -> Void

    public init(client: CoreClient, capture: CaptureService? = nil, onOpenSettings: @escaping () -> Void = {}) {
        search = MemorySearchModel(client: client)
        self.capture = capture
        self.onOpenSettings = onOpenSettings
    }
}

/// Debounced `memory.search`. An empty query lists recent activity.
@MainActor @Observable
public final class MemorySearchModel {
    static let debounce: Duration = .milliseconds(300)
    static let timeout: Duration = .seconds(10)

    enum Phase: Equatable {
        case idle, loading
        case results([MemoryHit])
        case memoryOff
        case failed(String)
    }

    var query = "" {
        didSet { if query != oldValue { schedule(debounced: true) } }
    }
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let request: @Sendable (Envelope) async throws -> Envelope
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let delay: Duration

    init(debounce: Duration = MemorySearchModel.debounce,
         request: @escaping @Sendable (Envelope) async throws -> Envelope) {
        self.delay = debounce
        self.request = request
    }

    public convenience init(client: CoreClient) {
        self.init(request: { try await client.request($0, timeout: MemorySearchModel.timeout) })
    }

    /// Searches now (tab shown, memory turned on, reconnected).
    func refresh() { schedule(debounced: false) }

    private func schedule(debounced: Bool) {
        task?.cancel()
        let q = query
        let request = self.request
        let delay = self.delay
        task = Task { [weak self] in
            if debounced {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            if case .results = self?.phase {} else { self?.phase = .loading }
            let next: Phase
            do {
                switch MemoryFormat.parse(try await request(try MemoryFormat.searchEnvelope(query: q))) {
                case .hits(let hits): next = .results(hits)
                case .memoryOff: next = .memoryOff
                case .failed(let message): next = .failed(message)
                }
            } catch CoreClientError.notConnected {
                next = .failed("Not connected to the core.")
            } catch CoreClientError.timeout {
                next = .failed("The core did not answer. Try again.")
            } catch {
                guard !Task.isCancelled else { return }   // superseded by a newer search
                next = .failed("The search failed. Try again.")
            }
            guard !Task.isCancelled else { return }
            self?.phase = next
        }
    }
}

/// Search what you have read and written, plus memory and capture status.
struct MemoryTab: View {
    let store: AppStore
    let memory: MemoryServices

    var body: some View {
        @Bindable var search = memory.search
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search memory", text: $search.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !search.query.isEmpty {
                    Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            MemoryStatusLine(status: store.memory, capture: memory.capture)
        }
        .onAppear { search.refresh() }
        .onChange(of: store.memory.enabled) { _, _ in search.refresh() }
        .onChange(of: store.connection) { _, c in if c == .connected { search.refresh() } }
    }

    @ViewBuilder private var content: some View {
        switch memory.search.phase {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .memoryOff:
            VStack(spacing: 6) {
                Image(systemName: "brain").font(.system(size: 18)).foregroundStyle(.secondary)
                Text("Memory is off").font(.system(size: 12, weight: .medium))
                Text("Turn it on to search what you read and write. Text stays on this Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Memory Settings", action: memory.onOpenSettings)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            Label { Text(verbatim: message) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.system(size: 11))
                .foregroundStyle(Theme.color(.attention))
        case .results(let hits):
            if hits.isEmpty {
                Text(memory.search.query.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "Nothing captured yet." : "No matches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    if memory.search.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(hits.enumerated()), id: \.offset) { MemoryHitRow(hit: $0.element) }
                        }
                    }
                }
            }
        }
    }
}

private struct MemoryHitRow: View {
    let hit: MemoryHit

    var body: some View {
        let title = MemoryFormat.title(hit.title)
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    Text(verbatim: MemoryFormat.when(hit.at, now: ctx.date))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            Text(verbatim: MemoryFormat.title(hit.sourceApp))
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Text(verbatim: MemoryFormat.snippet(hit.snippet))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct MemoryStatusLine: View {
    let status: MemoryStatus
    let capture: CaptureService?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.enabled {
                Text(verbatim: summary)
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let error = status.lastError, !error.isEmpty {
                Text(verbatim: SummarySanitizer.visible(error, singleLine: true).text)
                    .font(.system(size: 10)).foregroundStyle(Theme.color(.attention)).lineLimit(2)
            }
            if let capture { captureRow(capture) }
        }
    }

    private var summary: String {
        var parts = ["\(status.threads) threads"]
        if status.pending > 0 { parts.append("\(status.pending) pending") }
        parts.append("embedder " + (status.embedder.isEmpty ? "none" : status.embedder))
        parts.append("extractor " + (status.extractor.isEmpty ? "none" : status.extractor))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func captureRow(_ capture: CaptureService) -> some View {
        HStack(spacing: 6) {
            switch capture.status {
            case .off:
                EmptyView()
            case .needsAccessibility:
                Label("Capture needs Accessibility access (System Settings › Privacy & Security).",
                      systemImage: "lock")
                    .foregroundStyle(Theme.color(.attention))
            case .paused(let until):
                Label("Capture paused until \(until.formatted(date: .omitted, time: .shortened))",
                      systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Resume") { capture.resume() }.buttonStyle(.borderless)
            case .capturing:
                Label("Capturing on-screen text", systemImage: "record.circle")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Pause capture for 1 hour") { capture.pause(for: 3600) }.buttonStyle(.borderless)
            }
        }
        .font(.system(size: 10))
        .lineLimit(2)
    }
}
