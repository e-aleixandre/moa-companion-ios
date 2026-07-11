import Foundation
import MoaOpsCore

public protocol MoaOpsPresentationService: Sendable {
    func loadOverview() async throws -> OpsSnapshot
    func loadSitrep() async throws -> OpsBriefing
    func loadBlockers() async throws -> OpsBriefing
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse
    func startUpdates() async
    func stopUpdates() async
    func snapshotUpdates() async -> AsyncStream<OpsSnapshotUpdate>
    func webSocketState() async -> OpsWebSocketState
}

public actor MoaOpsLiveService: MoaOpsPresentationService {
    private let client: MoaOpsClient
    private let webSocket: MoaOpsWebSocketClient

    public init(baseURL: URL, session: URLSession = .shared, authentication: (any MoaOpsAuthenticationBootstrap)? = nil) throws {
        client = try MoaOpsClient(baseURL: baseURL, session: session, authentication: authentication)
        webSocket = try MoaOpsWebSocketClient(baseURL: baseURL, session: session, authentication: authentication)
    }

    public func loadOverview() async throws -> OpsSnapshot { try await client.overview() }
    public func loadSitrep() async throws -> OpsBriefing { try await client.sitrep() }
    public func loadBlockers() async throws -> OpsBriefing { try await client.blockers() }
    public func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        try await client.submitInstruction(instruction)
    }
    public func startUpdates() async { await webSocket.start() }
    public func stopUpdates() async { await webSocket.stop() }
    public func snapshotUpdates() async -> AsyncStream<OpsSnapshotUpdate> { await webSocket.updates() }
    public func webSocketState() async -> OpsWebSocketState { await webSocket.state }
}
