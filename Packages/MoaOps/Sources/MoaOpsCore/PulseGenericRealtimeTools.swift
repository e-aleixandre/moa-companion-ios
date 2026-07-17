import Foundation
import CoreFoundation

/// A provider-neutral function declaration for Pulse's generic Moa tools.
/// The call transport can turn these into Realtime function definitions without
/// giving the model a generic HTTP capability.
public struct PulseGenericToolDefinition: Encodable, Sendable {
    public let type = "function"
    public let name: String
    public let description: String
    public let parameters: PulseGenericToolSchema

    public init(name: String, description: String, parameters: PulseGenericToolSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public indirect enum PulseGenericToolSchema: Encodable, Sendable {
    case object(properties: [String: PulseGenericToolSchema], required: [String])
    case string(maximumLength: Int? = nil)
    case boolean
    case integer(minimum: Int? = nil, maximum: Int? = nil)
    case array(items: PulseGenericToolSchema, minimumCount: Int? = nil, maximumCount: Int? = nil)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .object(properties, required):
            try container.encode("object", forKey: .type)
            try container.encode(properties, forKey: .properties)
            try container.encode(required, forKey: .required)
            try container.encode(false, forKey: .additionalProperties)
        case let .string(maximumLength):
            try container.encode("string", forKey: .type)
            try container.encodeIfPresent(maximumLength, forKey: .maxLength)
        case .boolean:
            try container.encode("boolean", forKey: .type)
        case let .integer(minimum, maximum):
            try container.encode("integer", forKey: .type)
            try container.encodeIfPresent(minimum, forKey: .minimum)
            try container.encodeIfPresent(maximum, forKey: .maximum)
        case let .array(items, minimumCount, maximumCount):
            try container.encode("array", forKey: .type)
            try container.encode(items, forKey: .items)
            try container.encodeIfPresent(minimumCount, forKey: .minItems)
            try container.encodeIfPresent(maximumCount, forKey: .maxItems)
        }
    }

    private enum Key: String, CodingKey {
        case type, properties, required
        case additionalProperties = "additionalProperties"
        case maxLength, minimum, maximum, items, minItems, maxItems
    }
}

/// The complete, strict catalog exposed to the next direct Realtime call.
/// It intentionally contains no legacy operation endpoint or generic request
/// capability.
public enum PulseGenericToolCatalog {
    public static let definitions: [PulseGenericToolDefinition] = [
        definition("list_sessions", "List sessions and their pending asks or permissions, including the exact question or permission detail needed to describe and decide it.", .object(properties: [:], required: [])),
        definition("read_session", "Read a bounded page of messages and tool metadata for one session.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "limit": .integer(minimum: 1, maximum: PulseGenericToolBounds.pageLimit),
            "cursor": .string(maximumLength: PulseGenericToolBounds.cursor),
        ], required: ["session_id"])),
        definition("read_tool_detail", "Read the bounded output of one explicit tool item.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "item_id": .string(maximumLength: PulseGenericToolBounds.identifier),
        ], required: ["session_id", "item_id"])),
        definition("read_subagent", "Without job_id, list a session's subagents with their task and status. With a job_id from that list, read a bounded page of that subagent's transcript and tool metadata.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "job_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "limit": .integer(minimum: 1, maximum: PulseGenericToolBounds.pageLimit),
            "cursor": .string(maximumLength: PulseGenericToolBounds.cursor),
        ], required: ["session_id"])),
        definition("send_message", "Send a message or steer directly to one session.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "text": .string(maximumLength: PulseGenericToolBounds.message),
        ], required: ["session_id", "text"])),
        definition("respond_ask", "Answer one pending ask-user request.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "ask_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "answers": .array(items: .string(maximumLength: PulseGenericToolBounds.answer), minimumCount: 1, maximumCount: PulseGenericToolBounds.answers),
        ], required: ["session_id", "ask_id", "answers"])),
        definition("decide_permission", "Approve or deny one pending permission directly.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "permission_id": .string(maximumLength: PulseGenericToolBounds.identifier),
            "approved": .boolean,
            "feedback": .string(maximumLength: PulseGenericToolBounds.feedback),
        ], required: ["session_id", "permission_id", "approved"])),
        definition("create_session", "Create a session with optional title, working directory, and model.", .object(properties: [
            "title": .string(maximumLength: PulseGenericToolBounds.title),
            "cwd": .string(maximumLength: PulseGenericToolBounds.cwd),
            "model": .string(maximumLength: PulseGenericToolBounds.model),
        ], required: [])),
        definition("resume_session", "Resume one saved session.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
        ], required: ["session_id"])),
        definition("cancel_run", "Cancel the current run in one session.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
        ], required: ["session_id"])),
        definition("archive_session", "Archive one session.", .object(properties: [
            "session_id": .string(maximumLength: PulseGenericToolBounds.identifier),
        ], required: ["session_id"])),
    ]

    private static func definition(_ name: String, _ description: String, _ parameters: PulseGenericToolSchema) -> PulseGenericToolDefinition {
        .init(name: name, description: description, parameters: parameters)
    }
}

public enum PulseGenericToolBounds {
    public static let argumentBytes = 64 * 1024
    public static let identifier = 512
    public static let cursor = 4 * 1024
    public static let pageLimit = 100
    public static let message = 16 * 1024
    public static let answer = 4 * 1024
    public static let answers = 20
    public static let feedback = 4 * 1024
    public static let title = 512
    public static let cwd = 4 * 1024
    public static let model = 256
    public static let transcriptText = 12 * 1024
    public static let toolDetail = 16 * 1024
    /// This is below the Realtime function-output transport ceiling. `encode`
    /// always returns a complete JSON document, never a byte-sliced payload.
    public static let resultBytes = 24 * 1024
}

public enum PulseGenericToolRequest: Equatable, Sendable {
    case listSessions
    case readSession(sessionID: String, limit: Int, cursor: String?)
    case readToolDetail(sessionID: String, itemID: String)
    case readSubagent(sessionID: String, jobID: String?, limit: Int, cursor: String?)
    case sendMessage(sessionID: String, text: String)
    case respondAsk(sessionID: String, askID: String, answers: [String])
    case decidePermission(sessionID: String, permissionID: String, approved: Bool, feedback: String?)
    case createSession(title: String?, cwd: String?, model: String?)
    case resumeSession(sessionID: String)
    case cancelRun(sessionID: String)
    case archiveSession(sessionID: String)

    public init(name: String, arguments: Data) throws {
        guard arguments.count <= PulseGenericToolBounds.argumentBytes,
              let object = try JSONSerialization.jsonObject(with: arguments, options: []) as? [String: Any] else {
            throw PulseGenericToolError.invalidArguments
        }
        switch name {
        case "list_sessions":
            try exact(object, keys: [])
            self = .listSessions
        case "read_session":
            try exact(object, keys: ["session_id", "limit", "cursor"], required: ["session_id"])
            let sessionID = try identifier(object, "session_id")
            let limit = try optionalInteger(object, "limit", minimum: 1, maximum: PulseGenericToolBounds.pageLimit) ?? 20
            let cursor = try optionalCursor(object, "cursor")
            self = .readSession(sessionID: sessionID, limit: limit, cursor: cursor)
        case "read_tool_detail":
            try exact(object, keys: ["session_id", "item_id"], required: ["session_id", "item_id"])
            self = .readToolDetail(sessionID: try identifier(object, "session_id"), itemID: try identifier(object, "item_id"))
        case "read_subagent":
            try exact(object, keys: ["session_id", "job_id", "limit", "cursor"], required: ["session_id"])
            self = .readSubagent(sessionID: try identifier(object, "session_id"), jobID: try optionalIdentifier(object, "job_id"), limit: try optionalInteger(object, "limit", minimum: 1, maximum: PulseGenericToolBounds.pageLimit) ?? 20, cursor: try optionalCursor(object, "cursor"))
        case "send_message":
            try exact(object, keys: ["session_id", "text"], required: ["session_id", "text"])
            self = .sendMessage(sessionID: try identifier(object, "session_id"), text: try text(object, "text", maximum: PulseGenericToolBounds.message, allowEmpty: false))
        case "respond_ask":
            try exact(object, keys: ["session_id", "ask_id", "answers"], required: ["session_id", "ask_id", "answers"])
            self = .respondAsk(sessionID: try identifier(object, "session_id"), askID: try identifier(object, "ask_id"), answers: try answers(object))
        case "decide_permission":
            try exact(object, keys: ["session_id", "permission_id", "approved", "feedback"], required: ["session_id", "permission_id", "approved"])
            guard let approved = object["approved"] as? Bool else { throw PulseGenericToolError.invalidArguments }
            self = .decidePermission(sessionID: try identifier(object, "session_id"), permissionID: try identifier(object, "permission_id"), approved: approved, feedback: try optionalText(object, "feedback", maximum: PulseGenericToolBounds.feedback, allowEmpty: true))
        case "create_session":
            try exact(object, keys: ["title", "cwd", "model"])
            self = .createSession(title: try optionalText(object, "title", maximum: PulseGenericToolBounds.title, allowEmpty: true), cwd: try optionalText(object, "cwd", maximum: PulseGenericToolBounds.cwd, allowEmpty: true), model: try optionalText(object, "model", maximum: PulseGenericToolBounds.model, allowEmpty: true))
        case "resume_session":
            try exact(object, keys: ["session_id"], required: ["session_id"])
            self = .resumeSession(sessionID: try identifier(object, "session_id"))
        case "cancel_run":
            try exact(object, keys: ["session_id"], required: ["session_id"])
            self = .cancelRun(sessionID: try identifier(object, "session_id"))
        case "archive_session":
            try exact(object, keys: ["session_id"], required: ["session_id"])
            self = .archiveSession(sessionID: try identifier(object, "session_id"))
        default:
            throw PulseGenericToolError.unknownTool
        }
    }
}

public enum PulseGenericToolError: Error, Equatable, Sendable {
    case unknownTool
    case invalidArguments
}

/// The narrow Moa boundary used by generic tools. Tests can mock this protocol
/// without importing legacy projection types.
public protocol PulseGenericToolService: Sendable {
    func listSessions() async throws -> [MoaServeSessionInfo]
    func attention() async throws -> MoaServeAttentionResponse
    func readSession(sessionID: String, limit: Int, cursor: String?) async throws -> MoaServeConversationPage
    func readToolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail
    func listSubagents(sessionID: String) async throws -> MoaServeSubagentListResponse
    func readSubagent(sessionID: String, jobID: String, limit: Int, cursor: String?) async throws -> MoaServeSubagentPage
    func sendMessage(sessionID: String, text: String) async throws -> MoaServeSendMessageResponse
    func respondAsk(sessionID: String, askID: String, answers: [String]) async throws
    func decidePermission(sessionID: String, permissionID: String, approved: Bool, feedback: String?) async throws
    func createSession(title: String?, cwd: String?, model: String?) async throws -> MoaServeSessionInfo
    func resumeSession(sessionID: String) async throws -> MoaServeSessionInfo
    func cancelRun(sessionID: String) async throws
    func archiveSession(sessionID: String) async throws -> MoaServeArchiveSessionResponse
}

/// Production adapter over the generic paired-device client. Attachments and
/// the legacy projection surface are intentionally absent from this API.
public actor PulseDeviceGenericToolService: PulseGenericToolService {
    private let client: MoaPulseDeviceClient

    public init(client: MoaPulseDeviceClient) {
        self.client = client
    }

    public func listSessions() async throws -> [MoaServeSessionInfo] { try await client.listSessions() }
    public func attention() async throws -> MoaServeAttentionResponse { try await client.attention() }
    public func readSession(sessionID: String, limit: Int, cursor: String?) async throws -> MoaServeConversationPage { try await client.displayMessages(sessionID: sessionID, limit: limit, cursor: cursor) }
    public func readToolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail { try await client.toolDetail(sessionID: sessionID, itemID: itemID) }
    public func listSubagents(sessionID: String) async throws -> MoaServeSubagentListResponse { try await client.listSubagents(sessionID: sessionID) }
    public func readSubagent(sessionID: String, jobID: String, limit: Int, cursor: String?) async throws -> MoaServeSubagentPage { try await client.subagentMessages(sessionID: sessionID, jobID: jobID, limit: limit, cursor: cursor) }
    public func sendMessage(sessionID: String, text: String) async throws -> MoaServeSendMessageResponse { try await client.sendMessage(sessionID: sessionID, request: .init(text: text)) }
    public func respondAsk(sessionID: String, askID: String, answers: [String]) async throws { try await client.answerAsk(sessionID: sessionID, request: .init(id: askID, answers: answers)) }
    public func decidePermission(sessionID: String, permissionID: String, approved: Bool, feedback: String?) async throws { try await client.decidePermission(sessionID: sessionID, request: .init(id: permissionID, approved: approved, feedback: feedback)) }
    public func createSession(title: String?, cwd: String?, model: String?) async throws -> MoaServeSessionInfo { try await client.createSession(.init(model: model ?? "", title: title ?? "", cwd: cwd ?? "")) }
    public func resumeSession(sessionID: String) async throws -> MoaServeSessionInfo { try await client.resumeSession(sessionID: sessionID) }
    public func cancelRun(sessionID: String) async throws { try await client.cancelSession(sessionID: sessionID) }
    public func archiveSession(sessionID: String) async throws -> MoaServeArchiveSessionResponse { try await client.archiveSession(sessionID: sessionID, archived: true) }
}

public struct PulseGenericToolCall: Equatable, Sendable {
    public let id: String
    public let name: String
    public let arguments: Data

    public init(id: String, name: String, arguments: Data) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct PulseGenericToolExecution: Equatable, Sendable {
    public let callID: String
    public let output: String
    public let isError: Bool

    public init(callID: String, output: String, isError: Bool) {
        self.callID = callID
        self.output = output
        self.isError = isError
    }
}

/// Parses model JSON before it reaches Moa and serializes compact, bounded
/// result fields. It never returns server error bodies or request metadata.
public actor PulseGenericToolExecutor {
    private let service: any PulseGenericToolService

    public init(service: any PulseGenericToolService) {
        self.service = service
    }

    public func execute(_ call: PulseGenericToolCall) async -> PulseGenericToolExecution {
        do {
            let request = try PulseGenericToolRequest(name: call.name, arguments: call.arguments)
            let output = try await execute(request)
            return .init(callID: call.id, output: output, isError: false)
        } catch let error as PulseGenericToolError {
            let message = error == .unknownTool ? "La herramienta solicitada no existe." : "Los argumentos de la herramienta no son válidos."
            return .init(callID: call.id, output: errorOutput(message), isError: true)
        } catch {
            return .init(callID: call.id, output: errorOutput(readableError(error)), isError: true)
        }
    }

    private func execute(_ request: PulseGenericToolRequest) async throws -> String {
        switch request {
        case .listSessions:
            async let sessions = service.listSessions()
            async let attention = service.attention()
            let (sessionValues, attentionValues) = try await (sessions, attention)
            return try encode(listResult(sessions: sessionValues, attention: attentionValues))
        case let .readSession(sessionID, limit, cursor):
            return try encode(sessionResult(try await service.readSession(sessionID: sessionID, limit: limit, cursor: cursor)))
        case let .readToolDetail(sessionID, itemID):
            let detail = try await service.readToolDetail(sessionID: sessionID, itemID: itemID)
            return try encode(["session_id": sessionID, "item_id": itemID, "output": bounded(detail.output, PulseGenericToolBounds.toolDetail), "truncated": detail.truncated || detail.output.utf8.count > PulseGenericToolBounds.toolDetail])
        case let .readSubagent(sessionID, jobID, limit, cursor):
            if let jobID {
                let page = try await service.readSubagent(sessionID: sessionID, jobID: jobID, limit: limit, cursor: cursor)
                return try encode(subagentResult(page))
            }
            return try encode(subagentListResult(try await service.listSubagents(sessionID: sessionID)))
        case let .sendMessage(sessionID, text):
            _ = try await service.sendMessage(sessionID: sessionID, text: text)
            return try encode(["ok": true, "action": "message_sent", "session_id": sessionID])
        case let .respondAsk(sessionID, askID, answers):
            try await service.respondAsk(sessionID: sessionID, askID: askID, answers: answers)
            return try encode(["ok": true, "action": "ask_answered", "session_id": sessionID, "ask_id": askID])
        case let .decidePermission(sessionID, permissionID, approved, feedback):
            try await service.decidePermission(sessionID: sessionID, permissionID: permissionID, approved: approved, feedback: feedback)
            return try encode(["ok": true, "action": "permission_decided", "session_id": sessionID, "permission_id": permissionID, "approved": approved])
        case let .createSession(title, cwd, model):
            return try encode(createdResult(try await service.createSession(title: title, cwd: cwd, model: model)))
        case let .resumeSession(sessionID):
            _ = try await service.resumeSession(sessionID: sessionID)
            return try encode(["ok": true, "action": "session_resumed", "session_id": sessionID])
        case let .cancelRun(sessionID):
            try await service.cancelRun(sessionID: sessionID)
            return try encode(["ok": true, "action": "run_cancelled", "session_id": sessionID])
        case let .archiveSession(sessionID):
            _ = try await service.archiveSession(sessionID: sessionID)
            return try encode(["ok": true, "action": "session_archived", "session_id": sessionID])
        }
    }

    private func listResult(sessions: [MoaServeSessionInfo], attention: MoaServeAttentionResponse) -> [String: Any] {
        let bySession = Dictionary(grouping: attention.items, by: \.sessionID)
        let sessionResults: [[String: Any]] = sessions.map { session in
            var result: [String: Any] = ["id": session.id, "title": bounded(session.title, PulseGenericToolBounds.title), "state": session.state, "model": bounded(session.model, PulseGenericToolBounds.model), "updated_at": ISO8601DateFormatter.moaOps.string(from: session.updated)]
            let items = (bySession[session.id] ?? []).map { item in
                var attention: [String: Any] = [
                    "kind": bounded(item.kind, 128),
                    "session_id": item.sessionID,
                    "alias": bounded(item.alias, PulseGenericToolBounds.title),
                    "spoken": bounded(item.spoken, PulseGenericToolBounds.transcriptText),
                    "state": bounded(item.state, 128),
                ]
                if let refID = item.refID { attention["ref_id"] = refID }
                if let riskLevel = item.riskLevel, !riskLevel.isEmpty { attention["risk_level"] = bounded(riskLevel, 128) }
                if let riskFlags = item.riskFlags?.filter({ !$0.isEmpty }), !riskFlags.isEmpty { attention["risk_flags"] = riskFlags.map { bounded($0, 128) } }
                if let verbatim = item.verbatim { attention["verbatim"] = bounded(verbatim, PulseGenericToolBounds.transcriptText) }
                return attention
            }
            if !items.isEmpty { result["attention"] = items }
            if let sessionActivity = session.activity {
                var activity: [String: Any] = ["kind": sessionActivity.kind]
                if let detail = sessionActivity.detail, !detail.isEmpty { activity["detail"] = bounded(detail, PulseGenericToolBounds.transcriptText) }
                if let tool = sessionActivity.tool, !tool.isEmpty { activity["tool"] = bounded(tool, 128) }
                if let model = sessionActivity.model, !model.isEmpty { activity["model"] = bounded(model, 128) }
                if let count = sessionActivity.count { activity["count"] = count }
                result["activity"] = activity
            }
            return result
        }
        return ["sessions": sessionResults]
    }

    private func sessionResult(_ page: MoaServeConversationPage) -> [String: Any] {
        transcriptResult(sessionID: page.sessionID, title: page.title, jobID: nil, order: page.order, messages: page.messages, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    private func subagentResult(_ page: MoaServeSubagentPage) -> [String: Any] {
        transcriptResult(sessionID: page.sessionID, title: nil, jobID: page.jobID, order: page.order, messages: page.messages, nextCursor: page.nextCursor, hasMore: page.hasMore)
    }

    private func subagentListResult(_ response: MoaServeSubagentListResponse) -> [String: Any] {
        ["session_id": response.sessionID, "subagents": response.subagents.map { subagent in
            var result: [String: Any] = [
                "job_id": subagent.jobID,
                "task": bounded(subagent.task, PulseGenericToolBounds.transcriptText),
                "status": bounded(subagent.status, 128),
                "async": subagent.isAsync,
                "source": bounded(subagent.source, 128),
            ]
            if let model = subagent.model { result["model"] = bounded(model, PulseGenericToolBounds.model) }
            if let startedAt = subagent.startedAt { result["started_at"] = ISO8601DateFormatter.moaOps.string(from: startedAt) }
            if let finishedAt = subagent.finishedAt { result["finished_at"] = ISO8601DateFormatter.moaOps.string(from: finishedAt) }
            return result
        }]
    }

    private func transcriptResult(sessionID: String, title: String?, jobID: String?, order: String, messages source: [MoaServeConversationItem], nextCursor: String?, hasMore: Bool) -> [String: Any] {
        // The server pages newest-first. Keep the most recent page-worth and
        // present it chronologically so the last item is genuinely the newest.
        // Taking prefix(20) of the chronological list would drop the newest
        // messages — that was the "reads an older message, never the latest" bug.
        let ordered: [MoaServeConversationItem] = order == "newest_first"
            ? Array(source.prefix(20).reversed())
            : Array(source.suffix(20))
        let messages: [[String: Any]] = ordered.map { item in
            var result: [String: Any] = ["id": item.id, "role": item.role.rawValue]
            if let timestamp = item.timestamp { result["at"] = ISO8601DateFormatter.moaOps.string(from: timestamp) }
            if item.role != .tool, let text = item.text { result["text"] = bounded(text, PulseGenericToolBounds.transcriptText) }
            if item.role == .tool {
                if let tool = item.tool { result["tool"] = bounded(tool, 128) }
                if let action = item.action { result["action"] = bounded(action, 128) }
                if let target = item.target { result["target"] = bounded(target, 1_024) }
                if let summary = item.summary { result["summary"] = bounded(summary, 512) }
                if let status = item.status { result["status"] = bounded(status, 128) }
            }
            if item.truncated { result["truncated"] = true }
            return result
        }
        var result: [String: Any] = ["session_id": sessionID, "order": "chronological", "items": messages, "newest_included": true, "has_older": hasMore || source.count > ordered.count]
        if let title { result["title"] = bounded(title, PulseGenericToolBounds.title) }
        if let jobID { result["job_id"] = jobID }
        if let cursor = nextCursor { result["next_cursor"] = bounded(cursor, PulseGenericToolBounds.cursor) }
        return result
    }

    private func createdResult(_ session: MoaServeSessionInfo) -> [String: Any] {
        ["ok": true, "session": ["id": session.id, "title": bounded(session.title, PulseGenericToolBounds.title), "state": session.state, "model": bounded(session.model, PulseGenericToolBounds.model)]]
    }
}

private func exact(_ object: [String: Any], keys: Set<String>, required: Set<String> = []) throws {
    guard Set(object.keys).isSubset(of: keys), required.isSubset(of: Set(object.keys)) else { throw PulseGenericToolError.invalidArguments }
}

private func identifier(_ object: [String: Any], _ key: String) throws -> String {
    let value = try text(object, key, maximum: PulseGenericToolBounds.identifier, allowEmpty: false)
    guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
          !value.contains("/"), !value.contains("\\"), value != ".", value != ".." else { throw PulseGenericToolError.invalidArguments }
    return value
}

private func optionalIdentifier(_ object: [String: Any], _ key: String) throws -> String? {
    guard object.keys.contains(key) else { return nil }
    return try identifier(object, key)
}

private func optionalCursor(_ object: [String: Any], _ key: String) throws -> String? {
    guard object.keys.contains(key) else { return nil }
    let value = try text(object, key, maximum: PulseGenericToolBounds.cursor, allowEmpty: false)
    guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PulseGenericToolError.invalidArguments }
    return value
}

private func optionalText(_ object: [String: Any], _ key: String, maximum: Int, allowEmpty: Bool) throws -> String? {
    guard object.keys.contains(key) else { return nil }
    return try text(object, key, maximum: maximum, allowEmpty: allowEmpty)
}

private func text(_ object: [String: Any], _ key: String, maximum: Int, allowEmpty: Bool) throws -> String {
    guard let value = object[key] as? String,
          value.utf8.count <= maximum,
          !value.contains("\0"),
          allowEmpty || !value.isEmpty else { throw PulseGenericToolError.invalidArguments }
    return value
}

private func optionalInteger(_ object: [String: Any], _ key: String, minimum: Int, maximum: Int) throws -> Int? {
    guard let value = object[key] else { return nil }
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.rounded(.towardZero) == number.doubleValue,
          number.intValue >= minimum, number.intValue <= maximum else { throw PulseGenericToolError.invalidArguments }
    return number.intValue
}

private func answers(_ object: [String: Any]) throws -> [String] {
    guard let values = object["answers"] as? [Any], (1...PulseGenericToolBounds.answers).contains(values.count) else { throw PulseGenericToolError.invalidArguments }
    return try values.map { value in
        guard let answer = value as? String,
              answer.utf8.count <= PulseGenericToolBounds.answer,
              !answer.contains("\0") else { throw PulseGenericToolError.invalidArguments }
        return answer
    }
}

private func bounded(_ value: String, _ maximumBytes: Int) -> String {
    guard value.utf8.count > maximumBytes else { return value }
    var result = ""
    for character in value {
        guard result.utf8.count + String(character).utf8.count <= maximumBytes else { break }
        result.append(character)
    }
    return result
}

private func encode(_ object: Any) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    if data.count > PulseGenericToolBounds.resultBytes {
        let compact = try JSONSerialization.data(withJSONObject: ["error": "El resultado de Moa es demasiado grande; pide una página más pequeña."], options: [.sortedKeys])
        guard let text = String(data: compact, encoding: .utf8) else { throw PulseGenericToolError.invalidArguments }
        return text
    }
    guard let text = String(data: data, encoding: .utf8) else { throw PulseGenericToolError.invalidArguments }
    return text
}

private func errorOutput(_ message: String) -> String {
    (try? encode(["error": message])) ?? "{\"error\":\"Moa no pudo completar la solicitud.\"}"
}

private func readableError(_ error: Error) -> String {
    guard let error = error as? PulseCallError else { return "Moa no pudo completar la solicitud." }
    switch error {
    case .httpStatus(code: 401, _), .httpStatus(code: 403, _), .authentication, .invalidCredential:
        return "Pulse no está autorizado para completar esta solicitud."
    case .httpStatus(code: 400, _), .httpStatus(code: 404, _), .httpStatus(code: 409, _), .operationUnavailable:
        return "La sesión ya no está esperando esa decisión o pregunta; relee el estado antes de continuar."
    case .httpStatus(code: 429, _):
        return "Moa está limitando solicitudes; inténtalo de nuevo más tarde."
    case .transport, .httpStatus, .invalidResponse, .decoding, .invalidServerURL, .insecureTransport, .invalidPairingPayload, .secureStorageUnavailable:
        return "Moa no está disponible para completar la solicitud."
    }
}
