@preconcurrency import Foundation

public enum PulseAttentionWebSocketError: Error, Equatable, Sendable {
    case invalidServerURL
    case protocolVersion(Int)
    case inactive
    case decoding
}

/// The inexpensive, device-authenticated guardian channel. It owns one socket
/// generation at a time and repairs non-inactive failures with bounded jitter.
/// The server sends an authoritative `init` after every successful connection.
public actor PulseAttentionWebSocket {
    public typealias EventHandler = @Sendable (PulseAttentionServerMessage) -> Void
    public typealias StateHandler = @Sendable (State) -> Void

    public enum State: Equatable, Sendable { case stopped, connecting, connected, reconnecting(Int), inactive, failed }

    private let registration: PulseDeviceRegistration
    private let session: URLSession
    private let reconnectDelay: @Sendable (Int) -> TimeInterval
    private var task: URLSessionWebSocketTask?
    private var worker: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var shouldRun = false
    private var eventHandler: EventHandler?
    private var stateHandler: StateHandler?

    public init(registration: PulseDeviceRegistration, session: URLSession = PulseTransportFactory.ephemeralSession(), reconnectDelay: @escaping @Sendable (Int) -> TimeInterval = PulseAttentionWebSocket.defaultReconnectDelay) {
        self.registration = registration
        self.session = session
        self.reconnectDelay = reconnectDelay
    }

    public func start(onEvent: @escaping EventHandler, onState: @escaping StateHandler = { _ in }) {
        eventHandler = onEvent
        stateHandler = onState
        guard !shouldRun else { return }
        shouldRun = true
        generation &+= 1
        launch(generation: generation, attempt: 0)
    }

    public func stop() {
        shouldRun = false
        generation &+= 1
        worker?.cancel()
        worker = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        stateHandler?(.stopped)
    }

    /// Explicit owner action after the server reports another active device.
    public func reclaim() {
        guard shouldRun == false else { return }
        shouldRun = true
        generation &+= 1
        launch(generation: generation, attempt: 0)
    }

    public func ack(itemID: String) async { await send(.ack(itemID: itemID)) }
    public func ackTermination(terminationID: String) async { await send(.ackTermination(terminationID: terminationID)) }
    public func getStatus() async { await send(.getStatus) }

    private func launch(generation: UInt64, attempt: Int) {
        worker?.cancel()
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(generation: generation, attempt: attempt)
        }
    }

    private func run(generation: UInt64, attempt: Int) async {
        guard owns(generation) else { return }
        stateHandler?(attempt == 0 ? .connecting : .reconnecting(attempt))
        do {
            var request = URLRequest(url: try guardianURL())
            request.setValue("Moa-Device \(registration.credential)", forHTTPHeaderField: "Authorization")
            let socket = session.webSocketTask(with: request)
            task = socket
            socket.resume()
            guard owns(generation) else { socket.cancel(with: .normalClosure, reason: nil); return }
            stateHandler?(.connected)
            let ping = Task { [weak self] in
                guard let self else { return }
                await self.pingLoop(socket: socket, generation: generation)
            }
            defer { ping.cancel() }
            while owns(generation), !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .data(value): data = value
                case let .string(value): data = Data(value.utf8)
                @unknown default: throw PulseAttentionWebSocketError.decoding
                }
                let event = try JSONDecoder.moaOps.decode(PulseAttentionServerMessage.self, from: data)
                if let version = event.version, version != 1 { throw PulseAttentionWebSocketError.protocolVersion(version) }
                eventHandler?(event)
                if event.type == .inactive {
                    shouldRun = false
                    task = nil
                    socket.cancel(with: .normalClosure, reason: nil)
                    stateHandler?(.inactive)
                    return
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard owns(generation), !Task.isCancelled else { return }
            task = nil
            let nextAttempt = max(1, attempt + 1)
            stateHandler?(.reconnecting(nextAttempt))
            let delay = reconnectDelay(nextAttempt)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard owns(generation), !Task.isCancelled else { return }
            launch(generation: generation, attempt: nextAttempt)
        }
    }

    private func pingLoop(socket: URLSessionWebSocketTask, generation: UInt64) async {
        while owns(generation), !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            guard owns(generation), !Task.isCancelled else { return }
            do { try await socket.sendPing() }
            catch { socket.cancel(with: .goingAway, reason: nil); return }
        }
    }

    private func send(_ message: PulseAttentionClientMessage) async {
        guard let task, shouldRun else { return }
        guard let text = try? String(data: JSONEncoder.moaOps.encode(message), encoding: .utf8) else { return }
        do { try await task.send(.string(text)) }
        catch { task.cancel(with: .goingAway, reason: nil) }
    }

    private func guardianURL() throws -> URL {
        guard var components = URLComponents(url: registration.baseURL, resolvingAgainstBaseURL: false) else { throw PulseAttentionWebSocketError.invalidServerURL }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw PulseAttentionWebSocketError.invalidServerURL
        }
        components.path = "/api/pulse/guardian/ws"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw PulseAttentionWebSocketError.invalidServerURL }
        return url
    }

    private func owns(_ candidate: UInt64) -> Bool { shouldRun && generation == candidate }

    public static func defaultReconnectDelay(_ attempt: Int) -> TimeInterval {
        let capped = min(30.0, pow(2.0, Double(max(0, attempt - 1))))
        return capped * Double.random(in: 0.8 ... 1.2)
    }
}
