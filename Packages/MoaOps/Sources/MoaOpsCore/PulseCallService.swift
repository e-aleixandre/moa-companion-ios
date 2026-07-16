import Foundation

/// The app's only Moa boundary for a Pulse v1 call. It combines the generic
/// typed service with the one-purpose broker credential; no legacy projection
/// or operation-review API is present.
public protocol PulseCallServing: PulseGenericToolService {
    func mintRealtimeClientSecret() async throws -> PulseRealtimeClientCredential
    func invalidate() async
}

public actor MoaPulseDeviceService: PulseCallServing {
    private let transport: URLSession
    private let client: MoaPulseDeviceClient

    public init(registration: PulseDeviceRegistration, session: URLSession? = nil) throws {
        let selected = session ?? PulseTransportFactory.ephemeralSession()
        transport = selected
        client = try MoaPulseDeviceClient(registration: registration, session: selected)
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
    public func mintRealtimeClientSecret() async throws -> PulseRealtimeClientCredential { try await client.mintRealtimeClientSecret() }
    public func invalidate() async { transport.invalidateAndCancel() }
}
