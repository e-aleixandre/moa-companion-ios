@preconcurrency import Foundation

public struct OpsReconnectPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let maximumAttempts: Int?

    public init(initialDelay: TimeInterval = 1, maximumDelay: TimeInterval = 30, maximumAttempts: Int? = nil) {
        self.initialDelay = max(0, initialDelay)
        self.maximumDelay = max(self.initialDelay, maximumDelay)
        self.maximumAttempts = maximumAttempts
    }

    func delay(forAttempt attempt: Int) -> TimeInterval {
        min(initialDelay * pow(2, Double(max(0, attempt - 1))), maximumDelay)
    }
}

public enum OpsWebSocketState: Equatable, Sendable {
    case stopped
    case connecting
    case connected(version: UInt64)
    case reconnecting(attempt: Int)
}

public struct OpsSnapshotUpdate: Equatable, Sendable {
    public let version: UInt64
    public let snapshot: OpsSnapshot
    public let isInitial: Bool
}

/// A server-to-client-only client for `/api/ops/ws`. Each accepted envelope
/// replaces the complete local snapshot; it never sends application frames.
public actor MoaOpsWebSocketClient {
    public private(set) var state: OpsWebSocketState = .stopped
    public private(set) var version: UInt64?
    public private(set) var snapshot: OpsSnapshot?

    private let baseURL: URL
    private let session: URLSession
    private let authentication: (any MoaOpsAuthenticationBootstrap)?
    private let reconnectPolicy: OpsReconnectPolicy
    private var task: URLSessionWebSocketTask?
    private var runTask: Task<Void, Never>?
    private var runID: UUID?
    private var continuations: [UUID: AsyncStream<OpsSnapshotUpdate>.Continuation] = [:]

    public init(
        baseURL: URL,
        session: URLSession = .shared,
        authentication: (any MoaOpsAuthenticationBootstrap)? = nil,
        reconnectPolicy: OpsReconnectPolicy = .init()
    ) throws {
        guard baseURL.scheme == "http" || baseURL.scheme == "https", baseURL.host != nil else {
            throw MoaOpsClientError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.session = session
        self.authentication = authentication
        self.reconnectPolicy = reconnectPolicy
    }

    public func updates() -> AsyncStream<OpsSnapshotUpdate> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func start() {
        guard runTask == nil else { return }
        let id = UUID()
        runID = id
        runTask = Task { [weak self] in
            await self?.run(id: id)
        }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        runID = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .stopped
    }

    private func run(id: UUID) async {
        var attempts = 0
        while !Task.isCancelled {
            state = attempts == 0 ? .connecting : .reconnecting(attempt: attempts)
            do {
                try await authenticate()
                let webSocketTask = session.webSocketTask(with: try webSocketURL())
                task = webSocketTask
                webSocketTask.resume()
                try await receive(on: webSocketTask)
                attempts = 0
            } catch {
                attempts += 1
            }

            guard !Task.isCancelled else { break }
            if let maximumAttempts = reconnectPolicy.maximumAttempts, attempts >= maximumAttempts {
                break
            }
            state = .reconnecting(attempt: attempts)
            let delay = reconnectPolicy.delay(forAttempt: attempts)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        guard runID == id else { return }
        if !Task.isCancelled { state = .stopped }
        task = nil
        runTask = nil
        runID = nil
    }

    private func receive(on webSocketTask: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            let message = try await webSocketTask.receive()
            let data: Data
            switch message {
            case let .data(value): data = value
            case let .string(value):
                guard let encoded = value.data(using: .utf8) else { throw MoaOpsClientError.decoding }
                data = encoded
            @unknown default: throw MoaOpsClientError.decoding
            }
            let envelope: OpsWebSocketEnvelope
            do {
                envelope = try JSONDecoder.moaOps.decode(OpsWebSocketEnvelope.self, from: data)
            } catch {
                throw MoaOpsClientError.decoding
            }
            apply(envelope)
        }
    }

    private func apply(_ envelope: OpsWebSocketEnvelope) {
        switch envelope.type {
        case "init":
            version = envelope.version
            snapshot = envelope.snapshot
            state = .connected(version: envelope.version)
            yield(OpsSnapshotUpdate(version: envelope.version, snapshot: envelope.snapshot, isInitial: true))
        case "snapshot":
            guard version == nil || envelope.version > version! else { return }
            version = envelope.version
            snapshot = envelope.snapshot
            state = .connected(version: envelope.version)
            yield(OpsSnapshotUpdate(version: envelope.version, snapshot: envelope.snapshot, isInitial: false))
        default: break
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

    private func webSocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/ops/ws"), resolvingAgainstBaseURL: false) else {
            throw MoaOpsClientError.invalidBaseURL
        }
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw MoaOpsClientError.invalidBaseURL }
        return url
    }

    private func yield(_ update: OpsSnapshotUpdate) {
        for continuation in continuations.values { continuation.yield(update) }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
