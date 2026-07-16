@preconcurrency import Foundation

public actor MoaPulseDeviceClient {
    public let registration: PulseDeviceRegistration
    private let session: URLSession

    public init(registration: PulseDeviceRegistration, session: URLSession = PulseTransportFactory.ephemeralSession()) throws {
        _ = try PulseServerConfiguration(baseURL: registration.baseURL)
        self.registration = registration
        self.session = session
    }

    public func listSessions() async throws -> [MoaServeSessionInfo] {
        try await get(path: "api/sessions", as: [MoaServeSessionInfo].self)
    }

    public func attention() async throws -> MoaServeAttentionResponse {
        try await get(path: "api/attention", as: MoaServeAttentionResponse.self)
    }

    public func displayMessages(sessionID: String, limit: Int = 20, cursor: String? = nil) async throws -> MoaServeConversationPage {
        guard validRouteComponent(sessionID), (1...100).contains(limit) else {
            throw PulseCallError.operationUnavailable
        }
        if let cursor, !validOpaqueCursor(cursor) {
            throw PulseCallError.operationUnavailable
        }
        var components = URLComponents(url: sessionMessagesEndpoint(sessionID: sessionID), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor {
            queryItems.append(URLQueryItem(name: "cursor", value: cursor))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw PulseCallError.invalidServerURL }
        return try await get(url: url, as: MoaServeConversationPage.self)
    }

    public func toolDetail(sessionID: String, itemID: String) async throws -> MoaServeToolDetail {
        guard validRouteComponent(sessionID), validRouteComponent(itemID) else {
            throw PulseCallError.operationUnavailable
        }
        var components = URLComponents(url: sessionMessagesEndpoint(sessionID: sessionID), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "detail", value: "full"),
            URLQueryItem(name: "item_id", value: itemID),
        ]
        guard let url = components?.url else { throw PulseCallError.invalidServerURL }
        return try await get(url: url, as: MoaServeToolDetail.self)
    }

    public func listSubagents(sessionID: String) async throws -> MoaServeSubagentListResponse {
        guard validRouteComponent(sessionID) else {
            throw PulseCallError.operationUnavailable
        }
        let url = registration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("subagents")
        return try await get(url: url, as: MoaServeSubagentListResponse.self)
    }

    public func subagentMessages(sessionID: String, jobID: String, limit: Int = 20, cursor: String? = nil) async throws -> MoaServeSubagentPage {
        guard validRouteComponent(sessionID), validRouteComponent(jobID), (1...100).contains(limit),
              cursor.map(validOpaqueCursor) ?? true else {
            throw PulseCallError.operationUnavailable
        }
        var components = URLComponents(url: registration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("subagents")
            .appendingPathComponent(jobID), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components?.queryItems = items
        guard let url = components?.url else { throw PulseCallError.invalidServerURL }
        return try await get(url: url, as: MoaServeSubagentPage.self)
    }

    /// Creates a Serve session through the generic paired-device API.
    public func createSession(_ request: MoaServeCreateSessionRequest) async throws -> MoaServeSessionInfo {
        guard request.isValidMutationPayload,
              let body = encodeMoaServeMutationBody(request, maximumBytes: MoaServeMutationBodyLimit.normal) else {
            throw PulseCallError.operationUnavailable
        }
        return try await postMutation(path: "api/sessions", body: body, expectedStatus: 201, as: MoaServeSessionInfo.self)
    }

    /// Sends a user message or steer through the generic paired-device API.
    public func sendMessage(sessionID: String, request: MoaServeSendMessageRequest) async throws -> MoaServeSendMessageResponse {
        guard validRouteComponent(sessionID), request.isValidMutationPayload,
              let body = encodeMoaServeMutationBody(request, maximumBytes: MoaServeMutationBodyLimit.send) else {
            throw PulseCallError.operationUnavailable
        }
        return try await postMutation(url: sessionMutationEndpoint(sessionID: sessionID, action: "send"), body: body, expectedStatus: 202, as: MoaServeSendMessageResponse.self)
    }

    /// Resolves a pending ask-user request through the generic paired-device API.
    public func answerAsk(sessionID: String, request: MoaServeAskAnswerRequest) async throws {
        guard validRouteComponent(sessionID), request.isValidMutationPayload,
              let body = encodeMoaServeMutationBody(request, maximumBytes: MoaServeMutationBodyLimit.normal) else {
            throw PulseCallError.operationUnavailable
        }
        try await postMutationNoContent(url: sessionMutationEndpoint(sessionID: sessionID, action: "ask"), body: body)
    }

    /// Resolves a pending permission request through the generic paired-device API.
    public func decidePermission(sessionID: String, request: MoaServePermissionDecisionRequest) async throws {
        guard validRouteComponent(sessionID), request.isValidMutationPayload,
              let body = encodeMoaServeMutationBody(request, maximumBytes: MoaServeMutationBodyLimit.normal) else {
            throw PulseCallError.operationUnavailable
        }
        try await postMutationNoContent(url: sessionMutationEndpoint(sessionID: sessionID, action: "permission"), body: body)
    }

    /// Resumes a persisted session through the generic paired-device API.
    public func resumeSession(sessionID: String) async throws -> MoaServeSessionInfo {
        guard validRouteComponent(sessionID),
              let body = encodeMoaServeMutationBody(PulseEmptyObject(), maximumBytes: MoaServeMutationBodyLimit.normal) else {
            throw PulseCallError.operationUnavailable
        }
        return try await postMutation(url: sessionMutationEndpoint(sessionID: sessionID, action: "resume"), body: body, expectedStatus: 200, as: MoaServeSessionInfo.self)
    }

    /// Cancels the active run for a session through the generic paired-device API.
    public func cancelSession(sessionID: String) async throws {
        guard validRouteComponent(sessionID),
              let body = encodeMoaServeMutationBody(PulseEmptyObject(), maximumBytes: MoaServeMutationBodyLimit.normal) else {
            throw PulseCallError.operationUnavailable
        }
        try await postMutationNoContent(url: sessionMutationEndpoint(sessionID: sessionID, action: "cancel"), body: body)
    }

    /// Archives or unarchives a session through the generic paired-device API.
    public func archiveSession(sessionID: String, archived: Bool) async throws -> MoaServeArchiveSessionResponse {
        guard validRouteComponent(sessionID),
              let body = encodeMoaServeMutationBody(MoaServeArchiveSessionRequest(archived: archived), maximumBytes: MoaServeMutationBodyLimit.normal) else {
            throw PulseCallError.operationUnavailable
        }
        return try await postMutation(
            url: sessionMutationEndpoint(sessionID: sessionID, action: "archive"),
            body: body,
            expectedStatus: 200,
            as: MoaServeArchiveSessionResponse.self
        )
    }

    /// This credential is intentionally returned only to the immediate caller.
    /// It is not a Moa credential and must never be used on another Moa route.
    public func mintRealtimeClientSecret(now: Date = Date(), expirySkew: TimeInterval = 30) async throws -> PulseRealtimeClientCredential {
        var request = authenticatedRequest(url: endpoint("api/pulse/realtime/client-secret"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse, http.statusCode == 201 else {
            if let http = response as? HTTPURLResponse { try validate(http) }
            throw PulseCallError.invalidResponse
        }
        guard http.value(forHTTPHeaderField: "Cache-Control")?.lowercased().contains("no-store") == true else { throw PulseCallError.invalidResponse }
        do { return try JSONDecoder.moaOps.decode(PulseRealtimeClientCredential.self, from: data).validated(now: now, expirySkew: expirySkew) }
        catch let error as PulseCallError { throw error }
        catch { throw PulseCallError.decoding }
    }

    private func get<T: Decodable>(path: String, as type: T.Type) async throws -> T {
        try await get(url: endpoint(path), as: type)
    }

    private func get<T: Decodable>(url: URL, as type: T.Type) async throws -> T {
        var request = authenticatedRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        try validate(http)
        do {
            return try JSONDecoder.moaOps.decode(type, from: data)
        } catch {
            throw PulseCallError.decoding
        }
    }

    private func post<Body: Encodable, Response: Decodable>(path: String, body: Body, as type: Response.Type) async throws -> Response {
        var request = authenticatedRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.httpBody = try JSONEncoder.moaOps.encode(body)
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        try validate(http)
        do {
            return try JSONDecoder.moaOps.decode(type, from: data)
        } catch {
            throw PulseCallError.decoding
        }
    }

    private func postMutation<Response: Decodable>(path: String, body: Data, expectedStatus: Int, as type: Response.Type) async throws -> Response {
        try await postMutation(url: endpoint(path), body: body, expectedStatus: expectedStatus, as: type)
    }

    private func postMutation<Response: Decodable>(url: URL, body: Data, expectedStatus: Int, as type: Response.Type) async throws -> Response {
        var request = authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.httpBody = body
        let (data, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        guard http.statusCode == expectedStatus else {
            try validate(http)
            throw PulseCallError.invalidResponse
        }
        do {
            return try JSONDecoder.moaOps.decode(type, from: data)
        } catch {
            throw PulseCallError.decoding
        }
    }

    private func postMutationNoContent(url: URL, body: Data) async throws {
        var request = authenticatedRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Moa-Request")
        request.httpBody = body
        let (_, response) = try await perform(request, session: session)
        guard let http = response as? HTTPURLResponse else { throw PulseCallError.invalidResponse }
        guard http.statusCode == 204 else {
            try validate(http)
            throw PulseCallError.invalidResponse
        }
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Moa-Device \(registration.credential)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Request-ID")
        return request
    }

    private func endpoint(_ path: String) -> URL {
        registration.baseURL.appendingPathComponent(path)
    }

    private func sessionMessagesEndpoint(sessionID: String) -> URL {
        registration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent("messages")
    }

    private func sessionMutationEndpoint(sessionID: String, action: String) -> URL {
        registration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("sessions")
            .appendingPathComponent(sessionID)
            .appendingPathComponent(action)
    }
}

private struct PulseEmptyObject: Encodable {}

func validReference(_ value: String, limit: Int) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.unicodeScalars.count <= limit && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
}


private func validRouteComponent(_ value: String) -> Bool {
    guard validReference(value, limit: 512), value != ".", value != ".." else { return false }
    return !value.contains("/") && !value.contains("\\")
}

private func validOpaqueCursor(_ value: String) -> Bool {
    validReference(value, limit: 4_096)
}
