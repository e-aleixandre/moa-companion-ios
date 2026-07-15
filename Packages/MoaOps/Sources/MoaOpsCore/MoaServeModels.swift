import Foundation

/// The body accepted by `POST /api/sessions`.
public struct MoaServeCreateSessionRequest: Encodable, Equatable, Sendable {
    public let model: String
    public let title: String
    public let cwd: String

    public init(model: String = "", title: String = "", cwd: String = "") {
        self.model = model
        self.title = title
        self.cwd = cwd
    }
}

/// An inline attachment accepted by `POST /api/sessions/{id}/send`.
public struct MoaServeAttachment: Encodable, Equatable, Sendable {
    public let name: String
    public let mime: String
    public let data: String

    public init(name: String, mime: String, data: String) {
        self.name = name
        self.mime = mime
        self.data = data
    }
}

/// The body accepted by `POST /api/sessions/{id}/send`.
public struct MoaServeSendMessageRequest: Encodable, Equatable, Sendable {
    public let text: String
    public let attachments: [MoaServeAttachment]?
    public let steerID: String?

    enum CodingKeys: String, CodingKey {
        case text, attachments
        case steerID = "steer_id"
    }

    public init(text: String, attachments: [MoaServeAttachment]? = nil, steerID: String? = nil) {
        self.text = text
        self.attachments = attachments
        self.steerID = steerID
    }
}

/// The accepted response from `POST /api/sessions/{id}/send`.
public struct MoaServeSendMessageResponse: Decodable, Equatable, Sendable {
    public let action: String
    public let steerID: String?

    enum CodingKeys: String, CodingKey {
        case action
        case steerID = "steer_id"
    }
}

/// The body accepted by `POST /api/sessions/{id}/ask`.
public struct MoaServeAskAnswerRequest: Encodable, Equatable, Sendable {
    public let id: String
    public let answers: [String]

    public init(id: String, answers: [String]) {
        self.id = id
        self.answers = answers
    }
}

/// The body accepted by `POST /api/sessions/{id}/permission`.
public struct MoaServePermissionDecisionRequest: Encodable, Equatable, Sendable {
    public let id: String
    public let approved: Bool
    public let feedback: String?
    public let allow: String?
    public let rule: String?
    public let action: String?

    public init(
        id: String,
        approved: Bool,
        feedback: String? = nil,
        allow: String? = nil,
        rule: String? = nil,
        action: String? = nil
    ) {
        self.id = id
        self.approved = approved
        self.feedback = feedback
        self.allow = allow
        self.rule = rule
        self.action = action
    }
}

/// The response from `POST /api/sessions/{id}/archive`.
public struct MoaServeArchiveSessionResponse: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let archived: Bool
}

/// The body accepted by `POST /api/sessions/{id}/archive`.
public struct MoaServeArchiveSessionRequest: Encodable, Equatable, Sendable {
    public let archived: Bool

    public init(archived: Bool) {
        self.archived = archived
    }
}

extension MoaServeCreateSessionRequest {
    var isValidMutationPayload: Bool {
        validMoaServeField(model) && validMoaServeField(title) && validMoaServeField(cwd)
    }
}

extension MoaServeSendMessageRequest {
    var isValidMutationPayload: Bool {
        let attachmentList = attachments ?? []
        guard text.utf8.count <= 90 << 20,
              !text.contains("\0"),
              !text.isEmpty || !attachmentList.isEmpty,
              steerID.map(validMoaServeReferenceID) ?? true,
              attachmentList.count <= 8,
              attachmentList.allSatisfy(\.isValidMutationPayload),
              attachmentList.reduce(0, { $0 + Data(base64Encoded: $1.data)!.count }) <= 64 << 20 else {
            return false
        }
        return true
    }
}

extension MoaServeAttachment {
    var isValidMutationPayload: Bool {
        guard !name.isEmpty,
              !mime.isEmpty,
              validMoaServeField(name),
              validMoaServeField(mime),
              let decoded = Data(base64Encoded: data),
              !decoded.isEmpty,
              decoded.count <= 32 << 20 else {
            return false
        }
        return true
    }
}

extension MoaServeAskAnswerRequest {
    var isValidMutationPayload: Bool {
        validMoaServeReferenceID(id) && !answers.isEmpty &&
            answers.allSatisfy(validMoaServeField)
    }
}

extension MoaServePermissionDecisionRequest {
    var isValidMutationPayload: Bool {
        guard validMoaServeReferenceID(id),
              [feedback, allow, rule].allSatisfy({ $0.map(validMoaServeField) ?? true }) else {
            return false
        }
        return action.map(validMoaServeReferenceID) ?? true
    }
}

private func validMoaServeField(_ value: String) -> Bool {
    value.utf8.count <= 1 << 20 && !value.contains("\0")
}

private func validMoaServeReferenceID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty &&
        trimmed.unicodeScalars.count <= 512 &&
        !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
        value != "." && value != ".." &&
        !value.contains("/") && !value.contains("\\")
}

enum MoaServeMutationBodyLimit {
    static let normal = 1 << 20
    static let send = 90 << 20
}

func encodeMoaServeMutationBody<Body: Encodable>(_ body: Body, maximumBytes: Int) -> Data? {
    guard maximumBytes >= 0,
          let data = try? JSONEncoder.moaOps.encode(body),
          data.count <= maximumBytes else {
        return nil
    }
    return data
}

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
