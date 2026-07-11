@preconcurrency import Foundation

/// Read-only overlay for an active conversation. Serve's `init` is explicitly
/// a bounded tail, so it is merged over REST history and never treated as a
/// complete transcript.
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
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
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
            // Mobile network changes are normal. Reconnect with a bounded delay;
            // the next init is a tail overlay, not a history replacement.
            let delay = min(pow(2, Double(max(0, attempt - 1))), 30)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
            if let event = try ConversationWireEvent.decode(data) { yield(event) }
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
              var components = URLComponents(url: baseURL.appendingPathComponent("api").appendingPathComponent("sessions").appendingPathComponent(sessionID).appendingPathComponent("ws"), resolvingAgainstBaseURL: false) else {
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
    /// Decodes only the safe subset of Serve's existing per-session WS
    /// contract: init display tail, assistant text progression, completion,
    /// and state. All tool/thinking/unknown frames intentionally become nil.
    static func decodeServerEvent(_ data: Data) throws -> ConversationLiveEvent? {
        try ConversationWireEvent.decode(data)
    }
}

private struct ConversationWireEvent: Decodable {
    let type: String
    let data: WireData?

    enum CodingKeys: String, CodingKey { case type, data }

    static func decode(_ data: Data) throws -> ConversationLiveEvent? {
        let envelope = try JSONDecoder.moaOps.decode(ConversationWireEvent.self, from: data)
        switch envelope.type {
        case "init":
            guard case let .initial(initial)? = envelope.data else { return nil }
            return .initial(messages: initial.messages.compactMap(ConversationMessage.init), state: initial.state, historyTruncated: initial.historyTruncated)
        case "text_delta":
            guard case let .delta(delta)? = envelope.data else { return nil }
            return .textDelta(delta)
        case "message_end":
            guard case let .messageEnd(end)? = envelope.data else { return nil }
            return .messageEnded(.init(id: end.id ?? UUID().uuidString, role: "assistant", text: end.text))
        case "state_change":
            guard case let .state(state)? = envelope.data else { return nil }
            return .stateChanged(state)
        default:
            return nil // Thinking, tools, command output, and unknown events are never surfaced.
        }
    }

    enum WireData: Decodable {
        case initial(WireInitial)
        case delta(String)
        case messageEnd(WireMessageEnd)
        case state(String)

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: DynamicKey.self)
            if values.contains(DynamicKey("messages")) {
                self = .initial(try WireInitial(from: decoder))
            } else if let delta = try values.decodeIfPresent(String.self, forKey: DynamicKey("delta")) {
                self = .delta(delta)
            } else if let text = try values.decodeIfPresent(String.self, forKey: DynamicKey("text")) {
                self = .messageEnd(.init(text: text, id: try values.decodeIfPresent(String.self, forKey: DynamicKey("msg_id"))))
            } else if let state = try values.decodeIfPresent(String.self, forKey: DynamicKey("state")) {
                self = .state(state)
            } else {
                throw MoaOpsClientError.decoding
            }
        }
    }
}

private struct WireInitial: Decodable {
    let messages: [WireMessage]
    let state: String
    let historyTruncated: Bool

    enum CodingKeys: String, CodingKey { case messages, state; case historyTruncated = "history_truncated" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messages = try values.decode([WireMessage].self, forKey: .messages)
        state = try values.decode(String.self, forKey: .state)
        historyTruncated = try values.decodeIfPresent(Bool.self, forKey: .historyTruncated) ?? false
    }
}

private struct WireMessage: Decodable {
    let id: String?
    let role: String
    let timestamp: Date?
    let content: [WireContent]
    let hasCustom: Bool

    enum CodingKeys: String, CodingKey { case id = "msg_id"; case role, timestamp, content, custom }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        role = try values.decode(String.self, forKey: .role)
        content = try values.decodeIfPresent([WireContent].self, forKey: .content) ?? []
        hasCustom = values.contains(.custom) && !(try values.decodeNil(forKey: .custom))
        if let seconds = try? values.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: seconds)
        } else if let seconds = try? values.decode(Int.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: TimeInterval(seconds))
        } else {
            timestamp = nil
        }
    }

    func asConversationMessage() -> ConversationMessage? {
        guard (role == "user" || role == "assistant"), !hasCustom else { return nil }
        let text = content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return .init(id: id ?? "live-\(role)-\(text.hashValue)", role: role, timestamp: timestamp, text: text, omitted: content.contains { $0.type != "text" }, omittedBlocks: content.filter { $0.type != "text" }.count)
    }
}

private extension ConversationMessage {
    init?(_ wire: WireMessage) { guard let message = wire.asConversationMessage() else { return nil }; self = message }
}

private struct WireContent: Decodable {
    let type: String
    let text: String?
}

private struct WireMessageEnd {
    let text: String
    let id: String?
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
