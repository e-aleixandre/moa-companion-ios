import Foundation

// MARK: - Owner conversation API

public struct CompanionSession: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let archived: Bool
    public let state: String
    public let updated: Date

    public var isLive: Bool {
        state.lowercased() != "saved"
    }

    public var spanishState: String {
        switch state.lowercased() {
        case "idle": return "En espera"
        case "running": return "En marcha"
        case "permission": return "Espera permiso"
        case "error": return "Con error"
        case "saved": return "Guardada"
        default: return "Estado no disponible"
        }
    }

    public init(id: String, title: String, archived: Bool = false, state: String, updated: Date) {
        self.id = id
        self.title = title
        self.archived = archived
        self.state = state
        self.updated = updated
    }

    enum CodingKeys: String, CodingKey { case id, title, archived, state, updated }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        archived = try values.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        state = try values.decode(String.self, forKey: .state)
        updated = try values.decode(Date.self, forKey: .updated)
    }
}

public struct ConversationBranch: Codable, Equatable, Sendable {
    public let leafID: String
    public let source: String

    enum CodingKeys: String, CodingKey {
        case leafID = "leaf_id"
        case source
    }

    public init(leafID: String, source: String) {
        self.leafID = leafID
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        leafID = try values.decodeIfPresent(String.self, forKey: .leafID) ?? ""
        source = try values.decode(String.self, forKey: .source)
    }
}

/// A deliberately reduced owner-facing message. It is display text supplied by
/// Serve, never tool data, provider thinking, attachments, or local synthesis.
public struct ConversationMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let role: String
    public let timestamp: Date?
    public let text: String
    public let truncated: Bool
    public let omitted: Bool
    public let omittedBlocks: Int

    enum CodingKeys: String, CodingKey {
        case id, role, timestamp, text, truncated, omitted
        case omittedBlocks = "omitted_blocks"
    }

    public init(id: String, role: String, timestamp: Date? = nil, text: String, truncated: Bool = false, omitted: Bool = false, omittedBlocks: Int = 0) {
        self.id = id
        self.role = role
        self.timestamp = timestamp
        self.text = text
        self.truncated = truncated
        self.omitted = omitted
        self.omittedBlocks = omittedBlocks
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        role = try values.decode(String.self, forKey: .role)
        timestamp = try values.decodeIfPresent(Date.self, forKey: .timestamp)
        text = try values.decode(String.self, forKey: .text)
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
        omitted = try values.decodeIfPresent(Bool.self, forKey: .omitted) ?? false
        omittedBlocks = try values.decodeIfPresent(Int.self, forKey: .omittedBlocks) ?? 0
    }
}

public struct ConversationPage: Codable, Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let branch: ConversationBranch
    /// The hardened API always returns newest-first pages. Presentation must
    /// reverse each page before displaying it chronologically.
    public let order: String
    public let messages: [ConversationMessage]
    public let nextCursor: String?
    public let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case title, branch, order, messages
        case sessionID = "session_id"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

public struct ConversationSendRequest: Encodable, Equatable, Sendable {
    public let text: String
    public let attachments: [String]

    public init(text: String) {
        self.text = text
        attachments = []
    }
}

public struct ConversationSendResponse: Codable, Equatable, Sendable {
    public let action: OpsInstructionAction
}

public struct OpsBriefingRequest: Encodable, Equatable, Sendable {
    public let scope: String
    public let sessionIDs: [String]

    public init(sessionIDs: [String]) {
        scope = "selected"
        self.sessionIDs = sessionIDs
    }

    enum CodingKeys: String, CodingKey {
        case scope
        case sessionIDs = "session_ids"
    }
}

public struct ConversationBriefing: Codable, Equatable, Sendable {
    public let kind: String
    public let generatedAt: Date
    public let mode: String
    public let verifiedOps: [ConversationBriefingFact]
    public let items: [ConversationBriefingItem]

    enum CodingKeys: String, CodingKey {
        case kind, mode, items
        case generatedAt = "generated_at"
        case verifiedOps = "verified_ops"
    }
}

public struct ConversationBriefingFact: Codable, Equatable, Sendable, Identifiable {
    public let sourceID: String
    public let text: String
    public let provenance: String
    public var id: String { sourceID }

    enum CodingKeys: String, CodingKey {
        case text, provenance
        case sourceID = "source_id"
    }
}

public struct ConversationBriefingItem: Codable, Equatable, Sendable, Identifiable {
    public let text: String
    public let sourceIDs: [String]
    public let provenance: String
    public let suggestedAction: ConversationSuggestedAction?
    public var id: String { sourceIDs.joined(separator: ":") + ":" + text }

    enum CodingKeys: String, CodingKey {
        case text, provenance
        case sourceIDs = "source_ids"
        case suggestedAction = "suggested_action"
    }
}

public struct ConversationSuggestedAction: Codable, Equatable, Sendable {
    public let kind: String
    public let targetID: String

    enum CodingKeys: String, CodingKey {
        case kind
        case targetID = "target_id"
    }
}

public struct ConversationLiveInit: Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let branch: ConversationBranch
    public let state: String
    public let tail: [ConversationMessage]
    public let olderCursor: String?
    public let hasOlder: Bool

    public init(sessionID: String, title: String, branch: ConversationBranch, state: String, tail: [ConversationMessage], olderCursor: String?, hasOlder: Bool) {
        self.sessionID = sessionID
        self.title = title
        self.branch = branch
        self.state = state
        self.tail = tail
        self.olderCursor = olderCursor
        self.hasOlder = hasOlder
    }
}

/// This is the complete `/companion-ws` protocol. The server does not send
/// raw AgentMessage values on this route, so no client-side filtering exists.
public enum ConversationLiveEvent: Equatable, Sendable {
    case initial(ConversationLiveInit)
    case assistantDelta(text: String, truncated: Bool)
    case assistantFinal(ConversationMessage)
    case state(String)
}

public struct ConversationLiveState: Equatable, Sendable {
    public private(set) var messages: [ConversationMessage]
    public private(set) var state: String
    public private(set) var partialText: String
    public private(set) var historyIsBounded: Bool

    public init(messages: [ConversationMessage] = [], state: String = "", partialText: String = "", historyIsBounded: Bool = false) {
        self.messages = messages
        self.state = state
        self.partialText = partialText
        self.historyIsBounded = historyIsBounded
    }

    public mutating func apply(_ event: ConversationLiveEvent) {
        switch event {
        case let .initial(init):
            self.messages = merge(init.tail, into: self.messages)
            self.state = init.state
            historyIsBounded = init.hasOlder
            partialText = ""
        case let .assistantDelta(delta, _):
            partialText += delta
        case let .assistantFinal(message):
            messages = merge([message], into: messages)
            partialText = ""
        case let .state(state):
            self.state = state
        }
    }

    private func merge(_ incoming: [ConversationMessage], into current: [ConversationMessage]) -> [ConversationMessage] {
        var result = current
        var index = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
        for message in incoming {
            if let old = index[message.id] {
                result[old] = message
            } else {
                index[message.id] = result.count
                result.append(message)
            }
        }
        return result
    }
}
