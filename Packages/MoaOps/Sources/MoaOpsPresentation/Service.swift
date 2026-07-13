import Foundation
import MoaOpsCore

public struct MoaOpsSessionPrivacy: Equatable, Sendable {
    public let usesEphemeralSession: Bool
    public let persistsCookies: Bool

    public init(usesEphemeralSession: Bool, persistsCookies: Bool) {
        self.usesEphemeralSession = usesEphemeralSession
        self.persistsCookies = persistsCookies
    }
}

/// Builds the single shared transport used by the REST and WebSocket clients.
/// Token-protected Serve sessions must never use the shared cookie jar.
public enum MoaOpsSessionFactory {
    public static func privacy(accessTokenPresent: Bool) -> MoaOpsSessionPrivacy {
        accessTokenPresent
            ? .init(usesEphemeralSession: true, persistsCookies: false)
            : .init(usesEphemeralSession: false, persistsCookies: true)
    }

    static func ephemeralSession() -> URLSession {
        URLSession(configuration: ephemeralConfiguration())
    }

    static func ephemeralConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = HTTPCookieStorage()
        return configuration
    }
}

public protocol MoaOpsPresentationService: Sendable {
    func loadPulse(cursor: String?) async throws -> OpsPulse
    func loadOverview() async throws -> OpsSnapshot
    func loadSitrep() async throws -> OpsBriefing
    func loadBlockers() async throws -> OpsBriefing
    func ask(_ question: OpsAskRequest) async throws -> OpsAskResponse
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse
    func startUpdates() async
    func stopUpdates() async
    func snapshotUpdates() async -> AsyncStream<OpsSnapshotUpdate>
    func webSocketState() async -> OpsWebSocketState
    func invalidate() async
}

/// Service boundary for the owner-authorized companion vertical. It exposes
/// only Serve's display transcript and approved action endpoints.
public protocol MoaCompanionPresentationService: Sendable {
    func loadSessions() async throws -> [CompanionSession]
    func loadConversation(sessionID: String, limit: Int, cursor: String?) async throws -> ConversationPage
    func sendConversation(sessionID: String, text: String) async throws -> ConversationSendResponse
    func loadBriefing(sessionIDs: [String]) async throws -> ConversationBriefing
    func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse
    func loadPulse(cursor: String?) async throws -> OpsPulse
    func startConversationUpdates(sessionID: String) async
    func stopConversationUpdates() async
    func conversationUpdates() async -> AsyncStream<ConversationLiveEvent>
    func invalidate() async
}

public actor MoaCompanionLiveService: MoaCompanionPresentationService {
    private let client: MoaOpsClient
    private let baseURL: URL
    private let transport: URLSession
    private let authentication: (any MoaOpsAuthenticationBootstrap)?
    private let ephemeralSession: URLSession?
    private var conversationSocket: MoaConversationWebSocketClient?

    public init(baseURL: URL, session: URLSession? = nil, authentication: (any MoaOpsAuthenticationBootstrap)? = nil) throws {
        let mustIsolate = authentication != nil
        let selectedTransport = mustIsolate ? MoaOpsSessionFactory.ephemeralSession() : (session ?? .shared)
        transport = selectedTransport
        ephemeralSession = mustIsolate ? selectedTransport : nil
        self.baseURL = baseURL
        self.authentication = authentication
        client = try MoaOpsClient(baseURL: baseURL, session: selectedTransport, authentication: authentication)
    }

    public func loadSessions() async throws -> [CompanionSession] { try await client.sessions() }
    public func loadConversation(sessionID: String, limit: Int, cursor: String?) async throws -> ConversationPage {
        try await client.conversation(sessionID: sessionID, limit: limit, cursor: cursor)
    }
    public func sendConversation(sessionID: String, text: String) async throws -> ConversationSendResponse {
        try await client.sendConversation(sessionID: sessionID, text: text)
    }
    public func loadBriefing(sessionIDs: [String]) async throws -> ConversationBriefing { try await client.opsBriefing(sessionIDs: sessionIDs) }
    public func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        try await client.submitInstruction(instruction)
    }
    public func loadPulse(cursor: String?) async throws -> OpsPulse { try await client.pulse(cursor: cursor) }

    public func startConversationUpdates(sessionID: String) async {
        await conversationSocket?.stop()
        guard let socket = try? MoaConversationWebSocketClient(baseURL: baseURL, session: transport, authentication: authentication) else { return }
        conversationSocket = socket
        await socket.start(sessionID: sessionID)
    }

    public func stopConversationUpdates() async {
        await conversationSocket?.stop()
        conversationSocket = nil
    }

    public func conversationUpdates() async -> AsyncStream<ConversationLiveEvent> {
        guard let conversationSocket else { return AsyncStream { $0.finish() } }
        return await conversationSocket.updates()
    }

    public func invalidate() async {
        await stopConversationUpdates()
        guard let ephemeralSession else { return }
        if let cookies = ephemeralSession.configuration.httpCookieStorage?.cookies {
            for cookie in cookies { ephemeralSession.configuration.httpCookieStorage?.deleteCookie(cookie) }
        }
        ephemeralSession.invalidateAndCancel()
    }
}

public actor MoaOpsLiveService: MoaOpsPresentationService {
    private let client: MoaOpsClient
    private let webSocket: MoaOpsWebSocketClient
    private let ephemeralSession: URLSession?

    public init(baseURL: URL, session: URLSession? = nil, authentication: (any MoaOpsAuthenticationBootstrap)? = nil) throws {
        let mustIsolate = authentication != nil
        let transport = mustIsolate ? MoaOpsSessionFactory.ephemeralSession() : (session ?? .shared)
        ephemeralSession = mustIsolate ? transport : nil
        client = try MoaOpsClient(baseURL: baseURL, session: transport, authentication: authentication)
        webSocket = try MoaOpsWebSocketClient(baseURL: baseURL, session: transport, authentication: authentication)
    }

    public func loadPulse(cursor: String?) async throws -> OpsPulse { try await client.pulse(cursor: cursor) }
    public func loadOverview() async throws -> OpsSnapshot { try await client.overview() }
    public func loadSitrep() async throws -> OpsBriefing { try await client.sitrep() }
    public func loadBlockers() async throws -> OpsBriefing { try await client.blockers() }
    public func ask(_ question: OpsAskRequest) async throws -> OpsAskResponse { try await client.ask(question) }
    public func submitInstruction(_ instruction: OpsInstructionRequest) async throws -> OpsInstructionResponse {
        try await client.submitInstruction(instruction)
    }
    public func startUpdates() async { await webSocket.start() }
    public func stopUpdates() async { await webSocket.stop() }
    public func snapshotUpdates() async -> AsyncStream<OpsSnapshotUpdate> { await webSocket.updates() }
    public func webSocketState() async -> OpsWebSocketState { await webSocket.state }
    public func invalidate() async {
        await webSocket.stop()
        guard let ephemeralSession else { return }
        if let cookies = ephemeralSession.configuration.httpCookieStorage?.cookies {
            for cookie in cookies { ephemeralSession.configuration.httpCookieStorage?.deleteCookie(cookie) }
        }
        ephemeralSession.invalidateAndCancel()
    }
}
