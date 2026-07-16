@preconcurrency import Foundation

public enum OpenAIRealtimeClientError: Error, Equatable, Sendable {
    case missingCredential, invalidCredential, expiredCredential, invalidResponse, decoding, transport
}

/// One in-memory capability issued by the paired Moa device. It is never
/// persisted and is accepted only by OpenAI's fixed Realtime endpoint.
public struct PulseRealtimeClientCredential: Decodable, Equatable, Sendable {
    public let clientSecret: String
    public let expiresAt: Date
    public let transport: String
    public let endpoint: URL
    public let model: String

    enum CodingKeys: String, CodingKey { case clientSecret = "client_secret", expiresAt = "expires_at", transport, endpoint, model }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clientSecret = try values.decode(String.self, forKey: .clientSecret)
        expiresAt = Date(timeIntervalSince1970: try values.decode(TimeInterval.self, forKey: .expiresAt))
        transport = try values.decode(String.self, forKey: .transport)
        endpoint = try values.decode(URL.self, forKey: .endpoint)
        model = try values.decode(String.self, forKey: .model)
    }

    public func validated(now: Date = Date(), expirySkew: TimeInterval = 30, configuration: OpenAIRealtimeProviderConfiguration = .init()) throws -> Self {
        guard clientSecret.hasPrefix("ek_"), clientSecret.count > 3,
              expiresAt.timeIntervalSince(now) > max(0, expirySkew),
              transport == "websocket", model == configuration.model,
              endpoint.scheme?.lowercased() == "wss", endpoint.host?.lowercased() == "api.openai.com",
              endpoint.port == nil || endpoint.port == 443,
              endpoint.path == "/v1/realtime", endpoint.user == nil, endpoint.password == nil, endpoint.fragment == nil,
              let query = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.queryItems,
              query.count == 1, query.first?.name == "model", query.first?.value == model else {
            if expiresAt.timeIntervalSince(now) <= max(0, expirySkew) { throw OpenAIRealtimeClientError.expiredCredential }
            throw OpenAIRealtimeClientError.invalidCredential
        }
        return self
    }
}

public struct OpenAIRealtimeProviderConfiguration: Equatable, Sendable {
    public static let defaultModel = "gpt-realtime-2.1-mini"
    public let model: String

    public init(model: String = Self.defaultModel) {
        self.model = model
    }
}

public enum OpenAIRealtimePCM16 {
    public static let sampleRate = 24_000
    public static let channels = 1
    public static func appendEvent(_ pcm: Data) -> [String: Any] { ["type": "input_audio_buffer.append", "audio": pcm.base64EncodedString()] }
    public static func float32Samples(_ pcm: Data) -> [Float]? {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return nil }
        return pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 2).map { Float(Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)) / 32_768 }
        }
    }
}

public enum PulseRealtimeCallState: Equatable, Sendable { case connecting, listening, responding, ended, failed }

/// Narrow WebSocket boundary so the Realtime wire protocol is fixture-testable
/// without opening a network connection.
public protocol PulseRealtimeSocket: Sendable {
    func resume() async
    func send(text: String) async throws
    func receive() async throws -> String
    func cancel() async
}

public protocol PulseRealtimeSocketFactory: Sendable {
    func makeSocket(request: URLRequest) async -> any PulseRealtimeSocket
}

public actor URLSessionPulseRealtimeSocket: PulseRealtimeSocket {
    private let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }
    public func resume() { task.resume() }
    public func send(text: String) async throws { try await task.send(.string(text)) }
    public func receive() async throws -> String {
        let message = try await task.receive()
        switch message {
        case let .string(text): return text
        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else { throw OpenAIRealtimeClientError.decoding }
            return text
        @unknown default: throw OpenAIRealtimeClientError.decoding
        }
    }
    public func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

public struct URLSessionPulseRealtimeSocketFactory: PulseRealtimeSocketFactory, @unchecked Sendable {
    private let session: URLSession
    public init(session: URLSession) { self.session = session }
    public func makeSocket(request: URLRequest) async -> any PulseRealtimeSocket {
        URLSessionPulseRealtimeSocket(task: session.webSocketTask(with: request))
    }
}

public protocol PulseRealtimeCallControlling: Sendable {
    func appendPCM16(_ pcm: Data) async throws
    func end() async
}

public protocol PulseRealtimeCalling: Sendable {
    func beginCall(credential: PulseRealtimeClientCredential, configuration: OpenAIRealtimeProviderConfiguration, executor: PulseGenericToolExecutor, initialContext: String, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText: @escaping @Sendable (String) -> Void, onAudio: @escaping @Sendable (Data) -> Void) async throws -> any PulseRealtimeCallControlling
}

/// Direct, persistent WebSocket for one hands-free call. Audio stays iPhone ↔
/// OpenAI; only typed Moa function calls are delegated to the injected executor.
public actor OpenAIRealtimeCall: PulseRealtimeCallControlling {
    private let socket: any PulseRealtimeSocket
    private let executor: PulseGenericToolExecutor
    private let onState: @Sendable (PulseRealtimeCallState) -> Void
    private let onText: @Sendable (String) -> Void
    private let onAudio: @Sendable (Data) -> Void
    private var receiveTask: Task<Void, Never>?
    private var hasFunctionCallOutputsForCurrentResponse = false
    private var closed = false

    init(socket: any PulseRealtimeSocket, executor: PulseGenericToolExecutor, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText: @escaping @Sendable (String) -> Void, onAudio: @escaping @Sendable (Data) -> Void) {
        self.socket = socket; self.executor = executor; self.onState = onState; self.onText = onText; self.onAudio = onAudio
    }

    public func start(initialContext: String) async throws {
        await socket.resume()
        try await send(["type": "session.update", "session": [
            "type": "realtime", "instructions": PulseRealtimePrompt.system,
            "output_modalities": ["audio"], "tools": try toolJSONArray(), "tool_choice": "auto",
            "audio": ["input": ["format": ["type": "audio/pcm", "rate": OpenAIRealtimePCM16.sampleRate], "turn_detection": ["type": "semantic_vad"]], "output": ["format": ["type": "audio/pcm", "rate": OpenAIRealtimePCM16.sampleRate], "voice": "marin"]],
        ]])
        if !initialContext.isEmpty {
            try await send(["type": "conversation.item.create", "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": initialContext]]]])
        }
        onState(.listening)
        receiveTask = Task { [weak self] in await self?.receiveLoop() }
    }

    public func appendPCM16(_ pcm: Data) async throws {
        guard !closed, !pcm.isEmpty, pcm.count.isMultiple(of: 2) else { return }
        try await send(OpenAIRealtimePCM16.appendEvent(pcm))
    }

    public func end() async {
        guard !closed else { return }
        closed = true
        receiveTask?.cancel()
        await socket.cancel()
        onState(.ended)
    }

    private func receiveLoop() async {
        while !Task.isCancelled && !closed {
            do {
                let text = try await socket.receive()
                let data = Data(text.utf8)
                guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = event["type"] as? String else { throw OpenAIRealtimeClientError.decoding }
                switch type {
                case "response.output_audio.delta": if let audio = (event["delta"] as? String).flatMap(Data.init(base64Encoded:)) { onAudio(audio) }
                case "response.output_audio_transcript.delta", "response.output_text.delta": if let delta = event["delta"] as? String { onText(delta) }
                case "response.function_call_arguments.done":
                    guard let callID = event["call_id"] as? String, let name = event["name"] as? String else { throw OpenAIRealtimeClientError.decoding }
                    let arguments = Data((event["arguments"] as? String ?? "{}").utf8)
                    let result = await executor.execute(.init(id: callID, name: name, arguments: arguments))
                    try await send(["type": "conversation.item.create", "item": ["type": "function_call_output", "call_id": callID, "output": result.output]])
                    hasFunctionCallOutputsForCurrentResponse = true
                case "response.created": onState(.responding)
                case "response.done":
                    if hasFunctionCallOutputsForCurrentResponse {
                        hasFunctionCallOutputsForCurrentResponse = false
                        try await send(["type": "response.create", "response": ["output_modalities": ["audio"]]])
                    }
                    onState(.listening)
                case "error": throw OpenAIRealtimeClientError.invalidResponse
                default: break
                }
            } catch {
                if !Task.isCancelled && !closed { onState(.failed) }
                return
            }
        }
    }

    private func send(_ object: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else { throw OpenAIRealtimeClientError.decoding }
        try await socket.send(text: text)
    }

    private func toolJSONArray() throws -> [[String: Any]] {
        try PulseGenericToolCatalog.definitions.map { definition in
            try JSONSerialization.jsonObject(with: JSONEncoder.moaOps.encode(definition)) as? [String: Any] ?? [:]
        }
    }
}

public actor OpenAIRealtimeClient: PulseRealtimeCalling {
    private let socketFactory: any PulseRealtimeSocketFactory

    public init(session: URLSession = PulseTransportFactory.ephemeralSession()) {
        socketFactory = URLSessionPulseRealtimeSocketFactory(session: session)
    }

    public init(socketFactory: any PulseRealtimeSocketFactory) {
        self.socketFactory = socketFactory
    }

    public func beginCall(credential: PulseRealtimeClientCredential, configuration: OpenAIRealtimeProviderConfiguration = .init(), executor: PulseGenericToolExecutor, initialContext: String, onState: @escaping @Sendable (PulseRealtimeCallState) -> Void, onText: @escaping @Sendable (String) -> Void, onAudio: @escaping @Sendable (Data) -> Void) async throws -> any PulseRealtimeCallControlling {
        let credential = try credential.validated(configuration: configuration)
        var request = URLRequest(url: credential.endpoint)
        request.setValue("Bearer \(credential.clientSecret)", forHTTPHeaderField: "Authorization")
        let call = OpenAIRealtimeCall(socket: await socketFactory.makeSocket(request: request), executor: executor, onState: onState, onText: onText, onAudio: onAudio)
        try await call.start(initialContext: initialContext)
        return call
    }
}

public enum PulseRealtimePrompt {
    public static let system = """
    Eres Pulse, el intermediario de voz del propietario con sus sesiones de Moa. Habla en español, breve y natural. Usa exclusivamente las funciones tipadas declaradas. Puedes leer conversaciones completas cuando haga falta, pero no leas código ni salidas de herramientas en voz alta salvo que el propietario pida detalle explícitamente. Actúa directamente con las herramientas; pregunta solo si el destino es genuinamente ambiguo. Nunca menciones ni solicites URLs, credenciales, cabeceras, tokens o una herramienta HTTP genérica.
    """
}
