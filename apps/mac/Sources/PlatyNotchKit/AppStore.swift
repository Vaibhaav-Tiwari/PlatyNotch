import Foundation
import Observation

public enum ConnectionState: Sendable, Equatable {
    case connecting, connected, reconnecting
}

/// Observable UI state, fed by `CoreClient` events. Decode failures and unknown types are ignored.
@MainActor @Observable
public final class AppStore {
    public static let maxNotices = 20

    public private(set) var sessions: [Session] = []
    public private(set) var approvals: [Approval] = []
    public private(set) var usage = Usage()
    public private(set) var loops: [Loop] = []
    public private(set) var memory = MemoryStatus()
    public private(set) var edition = "free"
    public private(set) var connection: ConnectionState = .connecting
    public private(set) var notices: [Notice] = []

    public init() {}

    public func apply(_ event: CoreEvent) {
        switch event {
        case .connected: connection = .connected
        case .disconnected: connection = .reconnecting
        case .message(let env): apply(env)
        }
    }

    public func apply(_ env: Envelope) {
        guard let type = MessageType(rawValue: env.type) else { return }
        switch type {
        case .snapshot:
            guard let s: Snapshot = try? env.decode() else { return }
            sessions = s.sessions.sorted(by: Self.newestFirst)
            approvals = s.approvals.sorted(by: Self.oldestFirst)
            usage = s.usage
            loops = s.loops
            memory = s.memory
            edition = s.edition
        case .sessionUpdated:
            guard let s: Session = try? env.decode() else { return }
            if let i = sessions.firstIndex(where: { $0.key == s.key }) { sessions[i] = s } else { sessions.append(s) }
            sessions.sort(by: Self.newestFirst)
        case .sessionRemoved:
            guard let r: SessionRemoved = try? env.decode() else { return }
            sessions.removeAll { $0.key == r.key }
        case .approvalAdded:
            guard let a: Approval = try? env.decode() else { return }
            if let i = approvals.firstIndex(where: { $0.id == a.id }) { approvals[i] = a } else { approvals.append(a) }
            approvals.sort(by: Self.oldestFirst)
        case .approvalResolved:
            guard let r: ApprovalResolved = try? env.decode() else { return }
            approvals.removeAll { $0.id == r.id }
        case .usageUpdated:
            if let u: Usage = try? env.decode() { usage = u }
        case .loopsUpdated:
            if let l: [Loop] = try? env.decode() { loops = l }
        case .memoryStatus:
            if let m: MemoryStatus = try? env.decode() { memory = m }
        case .notice:
            guard let n: Notice = try? env.decode() else { return }
            notices.append(n)
            if notices.count > Self.maxNotices { notices.removeFirst(notices.count - Self.maxNotices) }
        default:
            break
        }
    }

    private static func oldestFirst(_ a: Approval, _ b: Approval) -> Bool {
        a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
    }

    /// Approvals stay visible while reconnecting, but cannot be answered.
    public var canAnswerApprovals: Bool { connection == .connected }

    private static func newestFirst(_ a: Session, _ b: Session) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt > b.updatedAt : a.key < b.key
    }
}
