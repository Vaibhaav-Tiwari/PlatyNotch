import Foundation

/// Protocol version; mirrors `protocol.Version` in core/protocol/protocol.go.
public let protocolVersion = 1

public enum MessageType: String, CaseIterable, Sendable {
    case hello, ping, pong, error
    case hookEvent = "hook.event"
    case hookAck = "hook.ack"
    case hookDecision = "hook.decision"
    case subscribe, snapshot
    case sessionUpdated = "session.updated"
    case sessionRemoved = "session.removed"
    case approvalAdded = "approval.added"
    case approvalResolved = "approval.resolved"
    case approvalDecide = "approval.decide"
    case usageUpdated = "usage.updated"
    case loopsUpdated = "loops.updated"
    case loopSetStatus = "loop.set_status"
    case notice
    case memoryStatus = "memory.status"
    case configReload = "config.reload"
    case captureText = "capture.text"
    case memorySearch = "memory.search"
    case memoryResults = "memory.results"
    case extRequest = "ext.request"
    case extEvent = "ext.event"
}

public enum ClientRole: String, Codable, Sendable {
    case hook, ui, capture, cli, ext
}

public enum SessionState: String, Codable, Sendable {
    case active, idle
    case waitingInput = "waiting_input"
    case blocked, exited
}

/// Wraps every message on the wire: one JSON object per line.
public struct Envelope: Codable, Sendable, Equatable {
    public var v: Int
    public var type: String
    public var id: String?
    public var data: RawJSON?

    public init(v: Int = protocolVersion, type: String, id: String? = nil, data: RawJSON? = nil) {
        self.v = v; self.type = type; self.id = id; self.data = data
    }

    public struct MissingData: Error {}

    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        guard let data else { throw MissingData() }
        return try data.decode(T.self)
    }

    public static func make<T: Encodable>(_ type: MessageType, id: String? = nil, _ data: T) throws -> Envelope {
        Envelope(type: type.rawValue, id: id, data: try RawJSON(encoding: data))
    }

    public static func make(_ type: MessageType, id: String? = nil) -> Envelope {
        Envelope(type: type.rawValue, id: id)
    }
}

public struct Hello: Codable, Sendable, Equatable {
    public var role: String
    public var client: String?
    public var version: Int
    public init(role: String, client: String? = nil, version: Int = protocolVersion) {
        self.role = role; self.client = client; self.version = version
    }
}

public struct ErrorMsg: Codable, Sendable, Equatable {
    public var message: String
    public init(message: String) { self.message = message }
}

public struct HookEvent: Codable, Sendable, Equatable {
    public var agent: String
    public var event: String
    public var payload: RawJSON?
    public var pid: Int?
    public var ppid: Int?
    public var tty: String?
    public var cwd: String?
    public var termProgram: String?
    public var wantDecision: Bool?
    public var at: Date

    enum CodingKeys: String, CodingKey {
        case agent, event, payload, pid, ppid, tty, cwd
        case termProgram = "term_program"
        case wantDecision = "want_decision"
        case at
    }
}

public struct HookAck: Codable, Sendable, Equatable {
    public var wait: Bool
    public var approvalID: String?
    public var timeoutMS: Int?

    enum CodingKeys: String, CodingKey {
        case wait
        case approvalID = "approval_id"
        case timeoutMS = "timeout_ms"
    }
}

public struct HookDecision: Codable, Sendable, Equatable {
    public var behavior: String
    public var message: String?
    public var source: String?
    public init(behavior: String, message: String? = nil, source: String? = nil) {
        self.behavior = behavior; self.message = message; self.source = source
    }
}

public struct Session: Codable, Sendable, Equatable, Identifiable {
    public var key: String
    public var agent: String
    public var agentName: String
    public var sessionID: String
    public var cwd: String?
    public var project: String?
    public var state: SessionState
    public var title: String?
    public var tool: String?
    public var message: String?
    public var pid: Int?
    public var tty: String?
    public var termProgram: String?
    public var subagents: Int?
    public var startedAt: Date
    public var updatedAt: Date

    public var id: String { key }

    public init(key: String, agent: String, agentName: String, sessionID: String, cwd: String? = nil,
                project: String? = nil, state: SessionState, title: String? = nil, tool: String? = nil,
                message: String? = nil, pid: Int? = nil, tty: String? = nil, termProgram: String? = nil,
                subagents: Int? = nil, startedAt: Date, updatedAt: Date) {
        self.key = key; self.agent = agent; self.agentName = agentName; self.sessionID = sessionID
        self.cwd = cwd; self.project = project; self.state = state; self.title = title; self.tool = tool
        self.message = message; self.pid = pid; self.tty = tty; self.termProgram = termProgram
        self.subagents = subagents; self.startedAt = startedAt; self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case key, agent
        case agentName = "agent_name"
        case sessionID = "session_id"
        case cwd, project, state, title, tool, message, pid, tty
        case termProgram = "term_program"
        case subagents
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }
}

public struct SessionRemoved: Codable, Sendable, Equatable {
    public var key: String
    public init(key: String) { self.key = key }
}

public struct Approval: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var sessionKey: String
    public var agent: String
    public var agentName: String
    public var project: String?
    public var cwd: String?
    public var tool: String
    public var summary: String
    public var input: RawJSON?
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, sessionKey: String, agent: String, agentName: String, project: String? = nil,
                cwd: String? = nil, tool: String, summary: String, input: RawJSON? = nil,
                createdAt: Date, expiresAt: Date) {
        self.id = id; self.sessionKey = sessionKey; self.agent = agent; self.agentName = agentName
        self.project = project; self.cwd = cwd; self.tool = tool; self.summary = summary
        self.input = input; self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionKey = "session_key"
        case agent
        case agentName = "agent_name"
        case project, cwd, tool, summary, input
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

public struct ApprovalDecide: Codable, Sendable, Equatable {
    public var id: String
    public var behavior: String
    public var message: String?
    public var source: String?
    public init(id: String, behavior: String, message: String? = nil, source: String? = nil) {
        self.id = id; self.behavior = behavior; self.message = message; self.source = source
    }
}

public struct ApprovalResolved: Codable, Sendable, Equatable {
    public var id: String
    public var behavior: String
    public var source: String?

    public init(id: String, behavior: String, source: String? = nil) {
        self.id = id; self.behavior = behavior; self.source = source
    }
}

public struct Window: Codable, Sendable, Equatable {
    public var usedPercent: Double
    public var resetsAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }
}

public struct Limits: Codable, Sendable, Equatable {
    public var fiveHour: Window?
    public var weekly: Window?
    public var extra: [String: Window]?
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case weekly, extra
        case updatedAt = "updated_at"
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var claude: Limits?
    public var codex: Limits?

    public init(claude: Limits? = nil, codex: Limits? = nil) { self.claude = claude; self.codex = codex }
}

public struct Loop: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var details: String?
    public var kind: String
    public var status: String
    public var sourceApp: String?
    public var sourceThread: String?
    public var quote: String?
    public var dueAt: Date?
    public var detectedAt: Date
    public var resolvedAt: Date?
    public var evidence: String?

    public init(id: String, title: String, details: String? = nil, kind: String, status: String,
                sourceApp: String? = nil, sourceThread: String? = nil, quote: String? = nil, dueAt: Date? = nil,
                detectedAt: Date, resolvedAt: Date? = nil, evidence: String? = nil) {
        self.id = id; self.title = title; self.details = details; self.kind = kind; self.status = status
        self.sourceApp = sourceApp; self.sourceThread = sourceThread; self.quote = quote; self.dueAt = dueAt
        self.detectedAt = detectedAt; self.resolvedAt = resolvedAt; self.evidence = evidence
    }

    enum CodingKeys: String, CodingKey {
        case id, title, details, kind, status
        case sourceApp = "source_app"
        case sourceThread = "source_thread"
        case quote
        case dueAt = "due_at"
        case detectedAt = "detected_at"
        case resolvedAt = "resolved_at"
        case evidence
    }
}

public struct LoopSetStatus: Codable, Sendable, Equatable {
    public var id: String
    public var status: String
    public var evidence: String?
    public init(id: String, status: String, evidence: String? = nil) {
        self.id = id; self.status = status; self.evidence = evidence
    }
}

public struct MemoryStatus: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var threads: Int
    public var versions: Int
    public var chunks: Int
    public var pending: Int
    public var embedder: String
    public var extractor: String
    public var lastError: String?

    public init(enabled: Bool = false, threads: Int = 0, versions: Int = 0, chunks: Int = 0, pending: Int = 0,
                embedder: String = "", extractor: String = "", lastError: String? = nil) {
        self.enabled = enabled; self.threads = threads; self.versions = versions; self.chunks = chunks
        self.pending = pending; self.embedder = embedder; self.extractor = extractor; self.lastError = lastError
    }

    enum CodingKeys: String, CodingKey {
        case enabled, threads, versions, chunks, pending, embedder, extractor
        case lastError = "last_error"
    }
}

public struct CaptureText: Codable, Sendable, Equatable {
    public var appBundle: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var text: String
    public var capturedAt: Date

    enum CodingKeys: String, CodingKey {
        case appBundle = "app_bundle"
        case appName = "app_name"
        case windowTitle = "window_title"
        case url, text
        case capturedAt = "captured_at"
    }
}

public struct MemorySearch: Codable, Sendable, Equatable {
    public var query: String
    public var limit: Int?
    public var since: Date?
    public var until: Date?
    public var app: String?
    public init(query: String, limit: Int? = nil, since: Date? = nil, until: Date? = nil, app: String? = nil) {
        self.query = query; self.limit = limit; self.since = since; self.until = until; self.app = app
    }
}

public struct MemoryHit: Codable, Sendable, Equatable {
    public var threadID: String
    public var title: String
    public var sourceApp: String
    public var snippet: String
    public var score: Double
    public var at: Date

    public init(threadID: String, title: String, sourceApp: String, snippet: String, score: Double, at: Date) {
        self.threadID = threadID; self.title = title; self.sourceApp = sourceApp
        self.snippet = snippet; self.score = score; self.at = at
    }

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case title
        case sourceApp = "source_app"
        case snippet, score, at
    }
}

public struct MemoryResults: Codable, Sendable, Equatable {
    public var hits: [MemoryHit]
}

public struct Notice: Codable, Sendable, Equatable {
    public var kind: String
    public var title: String
    public var body: String?
    public var sessionKey: String?

    public init(kind: String, title: String, body: String? = nil, sessionKey: String? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.sessionKey = sessionKey
    }

    enum CodingKeys: String, CodingKey {
        case kind, title, body
        case sessionKey = "session_key"
    }
}

public struct Snapshot: Codable, Sendable, Equatable {
    public var sessions: [Session]
    public var approvals: [Approval]
    public var usage: Usage
    public var loops: [Loop]
    public var memory: MemoryStatus
    public var edition: String

    public init(sessions: [Session] = [], approvals: [Approval] = [], usage: Usage = Usage(),
                loops: [Loop] = [], memory: MemoryStatus = MemoryStatus(), edition: String = "free") {
        self.sessions = sessions; self.approvals = approvals; self.usage = usage
        self.loops = loops; self.memory = memory; self.edition = edition
    }
}

public struct ExtMessage: Codable, Sendable, Equatable {
    public var ext: String
    public var kind: String
    public var data: RawJSON?
    public init(ext: String, kind: String, data: RawJSON? = nil) {
        self.ext = ext; self.kind = kind; self.data = data
    }
}
