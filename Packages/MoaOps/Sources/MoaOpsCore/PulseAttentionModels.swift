import Foundation

/// Wire DTOs for `/api/pulse/guardian/ws` protocol v1. `init` is an
/// authoritative snapshot: callers must replace, rather than merge, state.
public enum PulseAttentionPriority: String, Codable, Equatable, Sendable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
}

public enum PulseAttentionKind: String, Codable, Equatable, Sendable {
    case ask, permission, error
    case runOK = "run_ok"
    case goalEnded = "goal_ended"
    case goalStalled = "goal_stalled"
    case verifyFail = "verify_fail"
}

public struct PulseAttentionItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let priority: PulseAttentionPriority
    public let kind: PulseAttentionKind
    public let sessionID: String
    public let alias: String
    public let spoken: String
    public let state: String
    public let createdAt: Date
    public let refID: String
    public let riskLevel: String
    public let riskFlags: [String]
    public let verbatim: String

    enum CodingKeys: String, CodingKey {
        case id, priority, kind, alias, spoken, state, verbatim
        case sessionID = "session_id"
        case createdAt = "created_at"
        case refID = "ref_id"
        case riskLevel = "risk_level"
        case riskFlags = "risk_flags"
    }
}

public struct PulseSessionBrief: Codable, Equatable, Sendable, Identifiable {
    public let sessionID: String
    public let alias: String
    public let title: String
    public let state: String
    public let pendingAsks: Int
    public let pendingPerms: Int

    public var id: String { sessionID }
    enum CodingKeys: String, CodingKey {
        case alias, title, state
        case sessionID = "session_id"
        case pendingAsks = "pending_asks"
        case pendingPerms = "pending_perms"
    }
}

public struct PulseRunTerminationRef: Codable, Equatable, Sendable {
    public let sessionID: String
    public let runGen: UInt64
    public let messagesURL: String
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case runGen = "run_gen"
        case messagesURL = "messages_url"
    }
}

public struct PulseRunTermination: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let alias: String
    public let spoken: String
    public let summary: String
    public let createdAt: Date
    public let ref: PulseRunTerminationRef
    enum CodingKeys: String, CodingKey {
        case id, alias, spoken, summary, ref
        case sessionID = "session_id"
        case createdAt = "created_at"
    }
}

public struct PulseBriefing: Codable, Equatable, Sendable {
    public let priority: PulseAttentionPriority
    public let kind: PulseAttentionKind
    public let sessionID: String
    public let alias: String
    public let spoken: String
    public let termination: PulseRunTermination?
    enum CodingKeys: String, CodingKey {
        case priority, kind, alias, spoken, termination
        case sessionID = "session_id"
    }
}

public struct PulseAttentionServerMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case `init`, attention, itemUpdate = "item_update", briefing, roster, inactive, error }
    public let type: Kind
    public let version: Int?
    public let items: [PulseAttentionItem]?
    public let sessions: [PulseSessionBrief]?
    public let item: PulseAttentionItem?
    public let briefing: PulseBriefing?
    public let terminations: [PulseRunTermination]?
    public let requestID: String?
    public let code: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case type, items, sessions, item, briefing, terminations, code, message
        case version = "v"
        case requestID = "request_id"
    }
}

public enum PulseAttentionClientMessage: Encodable, Sendable, Equatable {
    case ack(itemID: String)
    case ackTermination(terminationID: String)
    case getStatus

    enum CodingKeys: String, CodingKey { case type, itemID = "item_id", terminationID = "termination_id" }
    enum TypeName: String, Encodable { case ack, ackTermination = "ack_termination", getStatus = "get_status" }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .ack(itemID):
            try container.encode(TypeName.ack, forKey: .type)
            try container.encode(itemID, forKey: .itemID)
        case let .ackTermination(terminationID):
            try container.encode(TypeName.ackTermination, forKey: .type)
            try container.encode(terminationID, forKey: .terminationID)
        case .getStatus:
            try container.encode(TypeName.getStatus, forKey: .type)
        }
    }
}
