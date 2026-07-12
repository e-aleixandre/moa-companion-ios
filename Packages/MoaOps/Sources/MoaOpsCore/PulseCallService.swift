@preconcurrency import Foundation

public protocol PulseCallService: Sendable {
    func loadPulse() async throws -> OpsPulse
    func loadSitrep() async throws -> OpsBriefing
    func loadStatus(target: String) async throws -> OpsStatusResult
    func loadSafeConversationEvidence(sessionID: String) async throws -> ConversationPage
    func prepareOperation(_ operation: PulseOperationPrepare) async throws -> PulseOperationResponse
    func confirmOperation(_ operationID: String) async throws -> PulseOperationResponse
    func loadOperation(_ operationID: String) async throws -> PulseOperationResponse
    func startOpsUpdates() async
    func stopOpsUpdates() async
    func opsUpdates() async -> AsyncStream<OpsSnapshotUpdate>
    func invalidate() async
}

/// Device-authenticated, server-to-client-only projection stream. It cannot
/// send application frames and never uses the dashboard session WebSocket.
public actor MoaPulseDeviceWebSocketClient {
    private let registration: PulseDeviceRegistration
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<OpsSnapshotUpdate>.Continuation] = [:]
    private var version: UInt64?

    public init(registration: PulseDeviceRegistration, session: URLSession) throws {
        _ = try PulseServerConfiguration(baseURL: registration.baseURL)
        self.registration = registration
        self.session = session
    }

    public func updates() -> AsyncStream<OpsSnapshotUpdate> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self, id] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func run() async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let socket = session.webSocketTask(with: try request())
                task = socket
                socket.resume()
                try await receive(socket)
                attempt = 0
            } catch {
                attempt += 1
            }
            guard !Task.isCancelled else { break }
            let delay = min(pow(2, Double(max(0, attempt - 1))), 30)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        task = nil
        runTask = nil
    }

    private func request() throws -> URLRequest {
        guard var components = URLComponents(url: registration.baseURL.appendingPathComponent("api/ops/ws"), resolvingAgainstBaseURL: false) else {
            throw PulseCallError.invalidServerURL
        }
        components.scheme = registration.baseURL.scheme?.lowercased() == "https" ? "wss" : "ws"
        guard let url = components.url else { throw PulseCallError.invalidServerURL }
        var request = URLRequest(url: url)
        request.setValue("Moa-Device \(registration.credential)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    private func receive(_ socket: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await socket.receive()
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value):
                guard let value = value.data(using: .utf8) else { throw PulseCallError.decoding }
                data = value
            @unknown default: throw PulseCallError.decoding
            }
            let envelope: OpsWebSocketEnvelope
            do {
                envelope = try JSONDecoder.moaOps.decode(OpsWebSocketEnvelope.self, from: data)
            } catch {
                throw PulseCallError.decoding
            }
            switch envelope.type {
            case "init":
                version = envelope.version
                yield(.init(version: envelope.version, snapshot: envelope.snapshot, isInitial: true))
            case "snapshot":
                guard version == nil || envelope.version > version! else { continue }
                version = envelope.version
                yield(.init(version: envelope.version, snapshot: envelope.snapshot, isInitial: false))
            default:
                throw PulseCallError.decoding
            }
        }
    }

    private func yield(_ update: OpsSnapshotUpdate) {
        for continuation in continuations.values { continuation.yield(update) }
    }

    private func removeContinuation(_ id: UUID) { continuations.removeValue(forKey: id) }
}

public actor MoaPulseDeviceService: PulseCallService {
    private let transport: URLSession
    private let client: MoaPulseDeviceClient
    private let socket: MoaPulseDeviceWebSocketClient

    public init(registration: PulseDeviceRegistration, session: URLSession? = nil) throws {
        let selected = session ?? PulseTransportFactory.ephemeralSession()
        transport = selected
        client = try MoaPulseDeviceClient(registration: registration, session: selected)
        socket = try MoaPulseDeviceWebSocketClient(registration: registration, session: selected)
    }

    public func loadPulse() async throws -> OpsPulse { try await client.pulse() }
    public func loadSitrep() async throws -> OpsBriefing { try await client.sitrep() }
    public func loadStatus(target: String) async throws -> OpsStatusResult { try await client.status(target: target) }
    public func loadSafeConversationEvidence(sessionID: String) async throws -> ConversationPage {
        try await client.displayMessages(sessionID: sessionID)
    }
    public func prepareOperation(_ operation: PulseOperationPrepare) async throws -> PulseOperationResponse {
        try await client.prepare(operation)
    }
    public func confirmOperation(_ operationID: String) async throws -> PulseOperationResponse {
        try await client.confirm(operationID: operationID)
    }
    public func loadOperation(_ operationID: String) async throws -> PulseOperationResponse {
        try await client.operation(operationID: operationID)
    }
    public func startOpsUpdates() async { await socket.start() }
    public func stopOpsUpdates() async { await socket.stop() }
    public func opsUpdates() async -> AsyncStream<OpsSnapshotUpdate> { await socket.updates() }

    public func invalidate() async {
        await socket.stop()
        transport.invalidateAndCancel()
    }
}
