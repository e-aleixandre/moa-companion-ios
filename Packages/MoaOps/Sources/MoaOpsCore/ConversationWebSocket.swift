@preconcurrency import Foundation

/// Read-only client for Serve's intentionally reduced `/companion-ws` route.
/// It never connects to the dashboard `/ws` endpoint and therefore never
/// decodes, filters, or retains raw agent/tool/thinking payloads.
public actor MoaConversationWebSocketClient {
    private let baseURL: URL
    private let session: URLSession
    private let authentication: (any MoaOpsAuthenticationBootstrap)?
    private var task: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<ConversationLiveEvent>.Continuation] = [:]

    public init(baseURL: URL, session: URLSession = .shared, authentication: (any MoaOpsAuthenticationBootstrap)? = nil) throws {
        guard baseURL.scheme == "http" || baseURL.scheme == "https", baseURL.host != nil else {
            throw MoaOpsClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session
        self.authentication = authentication
    }

    public func updates() -> AsyncStream<ConversationLiveEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self, id] _ in
                Task { @Sendable [weak self, id] in await self?.removeContinuation(id) }
            }
        }
    }

    public func start(sessionID: String) {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run(sessionID: sessionID) }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func run(sessionID: String) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await authenticate()
                let socket = session.webSocketTask(with: try webSocketURL(sessionID: sessionID))
                task = socket
                socket.resume()
                try await receive(socket)
                attempt = 0
            } catch {
                attempt += 1
            }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: UInt64(min(pow(2, Double(max(0, attempt - 1))), 30) * 1_000_000_000))
        }
        task = nil
        runTask = nil
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value):
                guard let value = value.data(using: .utf8) else { throw MoaOpsClientError.decoding }
                data = value
            @unknown default: throw MoaOpsClientError.decoding
            }
            if let event = try ConversationLiveEvent.decodeServerEvent(data) { yield(event) }
        }
    }

    private func authenticate() async throws {
        guard let authentication else { return }
        do {
            try await authentication.bootstrap(using: session, baseURL: baseURL)
        } catch let error as MoaOpsClientError {
            throw error
        } catch {
            throw MoaOpsClientError.authentication
        }
    }

    private func webSocketURL(sessionID: String) throws -> URL {
        guard !sessionID.isEmpty,
              var components = URLComponents(url: baseURL.appendingPathComponent("api").appendingPathComponent("sessions").appendingPathComponent(sessionID).appendingPathComponent("companion-ws"), resolvingAgainstBaseURL: false) else {
            throw MoaOpsClientError.invalidBaseURL
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw MoaOpsClientError.invalidBaseURL }
        return url
    }

    private func yield(_ event: ConversationLiveEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
}

public extension ConversationLiveEvent {
    static func decodeServerEvent(_ data: Data) throws -> ConversationLiveEvent? {
        try CompanionWireEvent.decode(data)
    }
}

/// Exact safe DTO schema emitted by `companion-ws`.
private struct CompanionWireEvent: Decodable {
    let type: String
    let initData: CompanionInitWire?
    let state: CompanionStateWire?
    let delta: CompanionDeltaWire?
    let message: ConversationMessage?

    enum CodingKeys: String, CodingKey {
        case type
        case initData = "init"
        case state, delta, message
    }

    static func decode(_ data: Data) throws -> ConversationLiveEvent? {
        let wire = try JSONDecoder.moaOps.decode(CompanionWireEvent.self, from: data)
        switch wire.type {
        case "init":
            guard let initData = wire.initData, initData.tailOrder == "oldest_first" else { throw MoaOpsClientError.decoding }
            return .initial(.init(sessionID: initData.sessionID, title: initData.title, branch: initData.branch, state: initData.state, tail: initData.tail, olderCursor: initData.olderCursor, hasOlder: initData.hasOlder))
        case "state":
            guard let state = wire.state else { throw MoaOpsClientError.decoding }
            return .state(state.state)
        case "assistant_delta":
            guard let delta = wire.delta else { throw MoaOpsClientError.decoding }
            return .assistantDelta(text: delta.text, truncated: delta.truncated)
        case "assistant_final":
            guard let message = wire.message, message.role == "assistant" else { throw MoaOpsClientError.decoding }
            return .assistantFinal(message)
        default:
            // Unknown frames are protocol incompatibility, not candidate raw
            // frames to filter. Closing/reconnecting is safer than displaying
            // an incomplete or unexpected transcript.
            throw MoaOpsClientError.decoding
        }
    }
}

private struct CompanionInitWire: Decodable {
    let sessionID: String
    let title: String
    let branch: ConversationBranch
    let state: String
    let tailOrder: String
    let tail: [ConversationMessage]
    let olderCursor: String?
    let hasOlder: Bool

    enum CodingKeys: String, CodingKey {
        case title, branch, state, tail
        case sessionID = "session_id"
        case tailOrder = "tail_order"
        case olderCursor = "older_cursor"
        case hasOlder = "has_older"
    }
}

private struct CompanionStateWire: Decodable { let state: String }
private struct CompanionDeltaWire: Decodable {
    let text: String
    let truncated: Bool

    enum CodingKeys: String, CodingKey { case text, truncated }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        text = try values.decode(String.self, forKey: .text)
        truncated = try values.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}
