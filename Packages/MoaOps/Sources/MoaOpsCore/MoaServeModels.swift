import Foundation

/// The public session DTO returned by `GET /api/sessions`.
public struct MoaServeSessionInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let archived: Bool
    public let state: String
    public let model: String
    public let provider: String
    public let thinking: String
    public let cwd: String
    public let created: Date
    public let updated: Date
    public let error: String?
    public let untrustedMCP: Bool
    public let planMode: String?
    public let planFile: String?
    public let contextPercent: Int
    public let permissionMode: String
    public let costUSD: Double
    public let cacheExpiresAt: Date?
    public let runStartedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, title, archived, state, model, provider, thinking, cwd, created, updated, error
        case untrustedMCP = "untrusted_mcp"
        case planMode = "plan_mode"
        case planFile = "plan_file"
        case contextPercent = "context_percent"
        case permissionMode = "permission_mode"
        case costUSD = "cost_usd"
        case cacheExpiresAt = "cache_expires_at"
        case runStartedAt = "run_started_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        state = try container.decode(String.self, forKey: .state)
        model = try container.decode(String.self, forKey: .model)
        provider = try container.decode(String.self, forKey: .provider)
        thinking = try container.decode(String.self, forKey: .thinking)
        cwd = try container.decode(String.self, forKey: .cwd)
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        untrustedMCP = try container.decodeIfPresent(Bool.self, forKey: .untrustedMCP) ?? false
        planMode = try container.decodeIfPresent(String.self, forKey: .planMode)
        planFile = try container.decodeIfPresent(String.self, forKey: .planFile)
        contextPercent = try container.decode(Int.self, forKey: .contextPercent)
        permissionMode = try container.decode(String.self, forKey: .permissionMode)
        costUSD = try container.decode(Double.self, forKey: .costUSD)
        cacheExpiresAt = try container.decodeIfPresent(Date.self, forKey: .cacheExpiresAt)
        runStartedAt = try container.decodeIfPresent(Date.self, forKey: .runStartedAt)
    }
}

/// The response returned by `GET /api/attention`.
public struct MoaServeAttentionResponse: Codable, Equatable, Sendable {
    public let items: [MoaServeAttentionItem]
}

public struct MoaServeAttentionItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let priority: Int
    public let kind: String
    public let sessionID: String
    public let alias: String
    public let spoken: String
    public let state: String
    public let createdAt: Date
    public let refID: String?
    public let riskLevel: String?
    public let riskFlags: [String]?
    public let requiresVerbatimConfirm: Bool?
    public let verbatim: String?

    enum CodingKeys: String, CodingKey {
        case id, priority, kind, alias, spoken, state, verbatim
        case sessionID = "session_id"
        case createdAt = "created_at"
        case refID = "ref_id"
        case riskLevel = "risk_level"
        case riskFlags = "risk_flags"
        case requiresVerbatimConfirm = "requires_verbatim_confirm"
    }
}

/// The newest-first transcript page returned by `GET /api/sessions/{id}/messages`.
public struct MoaServeConversationPage: Codable, Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let branch: MoaServeConversationBranch
    public let order: String
    public let messages: [MoaServeConversationItem]
    public let nextCursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case title, branch, order, messages
        case sessionID = "session_id"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

public struct MoaServeConversationBranch: Codable, Equatable, Sendable {
    public let leafID: String?
    public let source: String

    enum CodingKeys: String, CodingKey {
        case source
        case leafID = "leaf_id"
    }
}

public enum MoaServeConversationRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case tool
}

/// A transcript item. User and assistant items retain their `text`; tool items
/// expose only metadata and require a separate detail request for output.
public struct MoaServeConversationItem: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: MoaServeConversationRole
    public let timestamp: Date?
    public let text: String?
    public let truncated: Bool
    public let omitted: Bool
    public let omittedBlocks: Int
    public let tool: String?
    public let summary: String?
    public let status: String?

    enum CodingKeys: String, CodingKey {
        case id, role, timestamp, text, truncated, omitted, tool, summary, status
        case omittedBlocks = "omitted_blocks"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(MoaServeConversationRole.self, forKey: .role)
        timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        omitted = try container.decodeIfPresent(Bool.self, forKey: .omitted) ?? false
        omittedBlocks = try container.decodeIfPresent(Int.self, forKey: .omittedBlocks) ?? 0
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        status = try container.decodeIfPresent(String.self, forKey: .status)
    }
}

/// The bounded output returned only by the explicit tool-detail query.
public struct MoaServeToolDetail: Codable, Equatable, Sendable {
    public let output: String
    public let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case output, truncated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        output = try container.decode(String.self, forKey: .output)
        truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
